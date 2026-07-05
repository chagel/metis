require "csv"

module Previewers
  # Plain text, markdown, JSON, XML — anything we can render as text.
  # Markdown gets the existing markdown helper on the preview page;
  # everything else stays inside a <pre>.
  class Text < Base
    # Content types we trust to be textual on sight. Marcel's
    # detection for source code is unreliable (a .rb file often comes
    # back as application/octet-stream), so we also accept anything
    # with a known code extension below.
    SUPPORTED_TYPES = %w[
      text/plain text/markdown text/html text/css text/csv text/xml
      application/json application/xml application/javascript
      text/javascript text/x-ruby text/x-python
    ].freeze

    SUPPORTED_EXTENSIONS = %w[
      .txt .md .markdown .json .xml .html .htm .css
      .js .ts .jsx .tsx .rb .py .go .rs .java .kt .swift
      .c .h .cpp .hpp .cs .php .sql .sh .bash .zsh
      .yml .yaml .toml .ini .conf .log .diff .patch
    ].freeze

    def self.handles?(blob)
      SUPPORTED_TYPES.include?(blob.content_type) ||
        SUPPORTED_EXTENSIONS.include?(File.extname(blob.filename.to_s).downcase)
    end

    def card_partial = "previewers/text_card"

    def preview_modes
      return %i[preview source] if markdown? || html?

      [ :source ]
    end

    def partial_for_mode(mode)
      case mode
      when :preview then markdown? ? "previewers/markdown_full" : "previewers/html_full"
      when :source then "previewers/text_full"
      end
    end

    # First N lines for the card. Streams off the blob — never loads
    # the whole file into a string.
    def head_lines(limit: INLINE_LINE_LIMIT)
      lines = []
      blob.open do |file|
        File.foreach(file.path, encoding: "utf-8") do |line|
          lines << line.scrub
          break if lines.size >= limit
        end
      end
      lines
    end

    def markdown?
      blob.content_type == "text/markdown" ||
        blob.filename.to_s.match?(/\.(md|markdown)\z/i)
    end

    def html?
      blob.content_type == "text/html" ||
        blob.filename.to_s.match?(/\.html?\z/i)
    end

    # blob.download returns ASCII-8BIT; scrub replaces invalid byte
    # sequences with U+FFFD instead of raising mid-render.
    def full_content = blob.download.force_encoding("UTF-8").scrub
  end
end
