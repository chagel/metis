# The run board's read model: a team's workflow runs grouped into status
# columns, within per-project swimlanes, scoped to one viewer's visibility.
# Pure projection — never writes run or task state.
class Board
  DONE_WINDOW = 24.hours

  COLUMNS = %i[running awaiting_approval awaiting_local done].freeze

  # Statuses whose runs are shown regardless of age; terminal runs are
  # bounded by the Done window.
  ACTIVE_STATUSES = %i[pending running awaiting_approval awaiting_local].freeze

  SCOPES = %i[all mine needs_me].freeze
  # The Done-column recency choices; "all" lifts the age bound entirely.
  DONE_WINDOWS = { "24h" => 24.hours, "7d" => 7.days, "2w" => 2.weeks,
                   "1m" => 1.month, "all" => nil }.freeze

  # Maps the seven WorkflowRun statuses onto the four board columns.
  COLUMN_FOR_STATUS = {
    "pending" => :running, "running" => :running,
    "awaiting_approval" => :awaiting_approval,
    "awaiting_local" => :awaiting_local,
    "completed" => :done, "failed" => :done, "cancelled" => :done
  }.freeze

  Lane = Struct.new(:project, :columns, keyword_init: true)

  def self.for(team:, user:, scope: :all, project_ids: [], window: DONE_WINDOW)
    new(team: team, user: user, scope: scope, project_ids: project_ids, window: window)
  end

  def initialize(team:, user:, scope: :all, project_ids: [], window: DONE_WINDOW)
    @team = team
    @user = user
    @scope = scope
    @project_ids = Array(project_ids)
    @window = window
  end

  # [Lane] ordered by each project's most-recently-active run; a synthetic
  # "no project" lane sorts last.
  def lanes
    @lanes ||= build_lanes
  end

  def any?
    runs.any?
  end

  # Run count per status column, summed across every lane.
  def column_totals
    @column_totals ||= COLUMNS.index_with { |column| lanes.sum { |lane| lane.columns[column].size } }
  end

  # Visible runs awaiting someone's action — the "needs you" badge count.
  def needs_you_count
    runs.count { |run| run.awaiting_approval? || run.awaiting_local? }
  end

  private

  attr_reader :team, :user, :scope, :project_ids, :window

  def runs
    @runs ||= load_runs
  end

  def load_runs
    ids = team.conversations.board_visible(user, scope, project_ids).select(:id)

    runs = WorkflowRun.where(conversation_id: ids)
    if scope == :needs_me
      runs = runs.awaiting
    elsif window
      runs = runs.where(status: ACTIVE_STATUSES)
                 .or(WorkflowRun.where(conversation_id: ids, updated_at: window.ago..))
    end
    runs.includes(:workflow, { tasks: :claimed_by_user },
                  conversation: [ :project, { user: { avatar_attachment: :blob } } ])
        .order(updated_at: :desc).to_a
  end

  def build_lanes
    grouped = runs.group_by { |run| run.conversation.project }
    ordered_projects = grouped.keys.sort_by do |project|
      [ project ? 0 : 1, -grouped[project].first.updated_at.to_i ]
    end

    ordered_projects.map do |project|
      Lane.new(project: project, columns: columns_for(grouped[project]))
    end
  end

  def columns_for(lane_runs)
    columns = COLUMNS.index_with { [] }
    lane_runs.each { |run| columns[COLUMN_FOR_STATUS.fetch(run.status)] << run }
    columns
  end
end
