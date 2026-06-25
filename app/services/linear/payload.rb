module Linear
  # Shape helpers for a Linear webhook payload, shared by the inbound
  # processor and the out-of-band backfill job so the entity paths live in
  # one place.
  module Payload
    module_function

    # The referenced issue's id — top-level on most entities, nested on a
    # Comment (which Linear serializes its issue shallowly).
    def issue_id(payload)
      data = payload["data"] || {}
      data["issueId"] || data.dig("issue", "id")
    end
  end
end
