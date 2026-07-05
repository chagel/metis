require "csv"

module Previewers
  # CSV both renders inline (first ~50 rows) and full on the preview
  # page. Always streamed — blob.download would load the whole file.
  class Csv < Base
    def self.handles?(blob)
      blob.content_type == "text/csv" || blob.filename.to_s.match?(/\.csv\z/i)
    end

    def card_partial = "previewers/csv_card"

    def preview_modes = [ :preview ]
    def partial_for_mode(_mode) = "previewers/csv_full"

    def head_rows(limit: INLINE_ROW_LIMIT)
      take_rows(limit)
    end

    def all_rows
      take_rows(nil)
    end

    private

    def take_rows(limit)
      rows = []
      blob.open do |file|
        ::CSV.foreach(file.path, encoding: "utf-8") do |row|
          rows << row.map { |cell| cell.is_a?(String) ? cell.scrub : cell }
          break if limit && rows.size >= limit
        end
      end
      rows
    end
  end
end
