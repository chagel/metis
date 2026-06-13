# See docs/skills.md.
class Skill < ApplicationRecord
  SKILL_MD = "SKILL.md"
  SLUG_FORMAT = /\A[a-z0-9][a-z0-9\-]*\z/

  MAX_FILE_SIZE = 2.megabytes
  MAX_FILE_PATH_LENGTH = 200
  MAX_FILE_PATH_DEPTH = 4
  FILE_PATH_SEGMENT = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

  DEFAULT_SKILL_MD = <<~MD
    ---
    name: my-skill
    description: When the agent should reach for this — one line.
    ---

    # My skill

    Walk the agent through what to do, step by step. Keep it short.
  MD

  belongs_to :team
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  has_many_attached :files

  validates :slug, presence: true,
                    uniqueness: { scope: :team_id },
                    format: { with: SLUG_FORMAT }
  validate :slug_not_in_repo_tree

  scope :enabled, -> { where(enabled: true) }

  def self.valid_file_path?(path)
    return false unless path.is_a?(String)

    path = path.strip
    return false if path.empty?
    return false if path.length > MAX_FILE_PATH_LENGTH
    return false if path == SKILL_MD
    return false if path.start_with?("/")

    segments = path.split("/")
    return false if segments.size > MAX_FILE_PATH_DEPTH
    segments.all? { |s| s.match?(FILE_PATH_SEGMENT) && s != ".." }
  end

  # Pull one field out of SKILL.md's YAML frontmatter. Avoids a Psych
  # dep for the two-field shape we actually use (name, description).
  def self.parse_field(body, field)
    return nil unless body.is_a?(String) && body.start_with?("---")

    match = body.match(/\A---\s*\n(.*?)\n---\s*\n/m)
    return nil unless match

    match[1].each_line do |line|
      next unless (m = line.match(/\A#{Regexp.escape(field)}:\s*(.*)/))

      return m[1].strip.gsub(/\A["']|["']\z/, "")
    end
    nil
  end

  def self.parse_description(content)
    parse_field(content, "description")
  end

  # SHA1 of the team's enabled skills (slug + updated_at). Stable across
  # runtimes so Workspace and Runtime::E2b can both detect drift the same way.
  def self.team_signature(team)
    payload = team.skills.enabled.order(:slug).pluck(:slug, :updated_at)
      .map { |slug, ts| "#{slug}:#{ts.to_i}" }.join(",")
    Digest::SHA1.hexdigest(payload)
  end

  # Upsert a team skill from a {relative_path => bytes} file map. Callers:
  # Workspace ingest (agent-authored) and SkillImporter (URL-imported).
  # `files` must include SKILL.md. Repo-shadowed slugs are rejected via
  # the model's slug_not_in_repo_tree validation. Raises on validation
  # failure; the caller decides how to surface it.
  def self.upsert_from_files(team:, slug:, files:, by:)
    body = files[SKILL_MD]
    raise ArgumentError, "missing #{SKILL_MD}" if body.blank?

    body = body.dup.force_encoding("UTF-8")
    skill = team.skills.find_or_initialize_by(slug: slug)
    skill.created_by ||= by
    skill.updated_by = by
    if (desc = parse_description(body)).present?
      skill.description = desc
    end
    skill.content_cache = body

    skill.files.purge if skill.persisted?
    skill.save!

    files.each { |rel, content| skill.replace_file!(rel, content) }
    skill
  end

  def skill_md_content
    return content_cache if content_cache.present?

    skill_md = files.find { |f| relative_path(f) == SKILL_MD }
    skill_md&.download&.force_encoding("UTF-8")
  end

  def replace_skill_md!(content)
    replace_file!(SKILL_MD, content, "text/markdown")
    self.content_cache = content
  end

  def replace_file!(relative_path, content, content_type = nil)
    raise ArgumentError, "Invalid relative path" if relative_path.include?("..")

    existing = files.find { |f| f.blob.metadata["relative_path"] == relative_path }
    existing&.purge

    content_type ||= Marcel::MimeType.for(name: relative_path)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(content),
      filename: File.basename(relative_path),
      content_type: content_type,
      metadata: { "relative_path" => relative_path }
    )
    files.attach(blob)
  end

  def extract_to(dir)
    files.each do |file|
      rel = Pathname.new(relative_path(file)).cleanpath.to_s
      next if rel.start_with?("..") || rel.start_with?("/")

      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, file.download)
    end
  end

  def file_list
    files.map { |f| relative_path(f) }.sort
  end

  def relative_path(file)
    file.blob.metadata["relative_path"] || file.filename.to_s
  end

  private

  # Repo skills and team skills share workspace/.pi/skills/ at runtime; a
  # team slug claiming a repo slug would silently override it.
  def slug_not_in_repo_tree
    return if slug.blank?
    return unless Agent::Workspace.repo_slugs.include?(slug)

    errors.add(:slug, :reserved)
  end
end
