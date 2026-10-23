class Message < ApplicationRecord
  belongs_to :chat
  has_many :tool_calls, dependent: :destroy

  enum :status, {
    pending: "pending",
    complete: "complete",
    failed: "failed"
  }

  validates :content, presence: true, unless: :content_optional?

  after_create_commit -> { broadcast_append_to chat, target: "messages" }, if: :broadcast?
  after_update_commit -> { broadcast_update_to chat }, if: :broadcast?

  scope :ordered, -> { order(created_at: :asc) }

  # Ruby's +blank?+ treats Unicode whitespace as blank, but PostgreSQL's
  # +[[:space:]]+ does not include NEL, NBSP, figure space, or narrow NBSP.
  # Add those four characters to the negated class so a pending audit owner
  # containing only Ruby-blank content stays hidden, matching broadcast
  # visibility. PostgreSQL regex character classes are Unicode-aware for the
  # remaining whitespace characters tested.
  NON_BLANK_CONTENT_PATTERN = "[^[:space:]#{[ 0x0085, 0x00A0, 0x2007, 0x202F ].pack("U*")}]".freeze

  # Audit owners are AssistantMessages persisted before a tool dispatch. A
  # pending or failed owner may be blank, but every other message keeps the
  # ordinary content requirement.
  scope :visible_in_conversation, -> {
    where(
      "type <> :assistant OR (status <> :failed AND (status <> :pending OR COALESCE(content, '') ~ :non_blank_content))",
      assistant: "AssistantMessage",
      failed: "failed",
      pending: "pending",
      non_blank_content: NON_BLANK_CONTENT_PATTERN
    )
  }

  private
    def content_optional?
      false
    end

    def broadcast?
      true
    end
end
