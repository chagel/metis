# The board's actor rail: who and what is acting on a team's runs, for one
# viewer. People carry the gates awaiting them; machines are bridge clients
# with a coarse online/stale light from the heartbeat. Read-only — and
# presence is deliberately coarse (one heartbeat per bridge session), so it
# distinguishes only online vs stale, never worker counts or deployments.
class BoardPresence
  ONLINE_WINDOW = 2.minutes

  Person = Struct.new(:member, :gate_ref, :gate_count, keyword_init: true) do
    def idle?
      gate_count.zero?
    end
  end

  Machine = Struct.new(:owner, :client, :online, :seen_at, :task_ref, keyword_init: true) do
    def online?
      online
    end
  end

  def self.for(team:, user:)
    new(team: team, user: user)
  end

  def initialize(team:, user:)
    @team = team
    @user = user
  end

  # Team members, those with an open gate first.
  def people
    @people ||= begin
      gates = gates_by_launcher
      @team.members.map { |member|
        refs = gates[member.id] || []
        Person.new(member: member, gate_ref: refs.first, gate_count: refs.size)
      }.sort_by { |person| [ person.idle? ? 1 : 0, person.member.display_label.downcase ] }
    end
  end

  # Every member that has minted a bridge token, online ones first.
  def machines
    @machines ||= begin
      claimed = claimed_task_by_user
      bridge_members.map { |member|
        Machine.new(
          owner: member, client: member.bridge_client,
          online: online?(member), seen_at: member.bridge_seen_at,
          task_ref: claimed[member.id]&.ref
        )
      }.sort_by { |machine| [ machine.online? ? 0 : 1, -(machine.seen_at&.to_i || 0) ] }
    end
  end

  def online_count
    machines.count(&:online?)
  end

  private

  attr_reader :team, :user

  def online?(member)
    member.bridge_seen_at.present? && member.bridge_seen_at > ONLINE_WINDOW.ago
  end

  def bridge_members
    @bridge_members ||= team.members.select { |member| member.bridge_token_digest.present? }
  end

  def visible_conversation_ids
    team.conversations.accessible_to(user).select(:id)
  end

  # launcher user id => [gate refs], from awaiting-approval runs the viewer
  # can see. A team-visible gate is attributed to the run's launcher.
  def gates_by_launcher
    WorkflowRun.where(conversation_id: visible_conversation_ids)
               .awaiting_approval
               .includes(:tasks, :conversation, :workflow)
               .each_with_object(Hash.new { |h, k| h[k] = [] }) do |run, acc|
      gate = run.tasks.find(&:awaiting_approval?)
      acc[run.conversation.user_id] << gate.ref if gate
    end
  end

  # member id => the running delegated task they hold, when its run is
  # visible to the viewer (never leak a private run's ref). Most recent claim
  # wins when a machine holds more than one.
  def claimed_task_by_user
    return {} if bridge_members.empty?

    Task.where(claimed_by_user_id: bridge_members.map(&:id), status: :running, delegated: true)
        .joins(workflow_run: :conversation)
        .merge(team.conversations.accessible_to(user))
        .includes(workflow_run: :workflow)
        .order(claimed_at: :desc)
        .group_by(&:claimed_by_user_id)
        .transform_values(&:first)
  end
end
