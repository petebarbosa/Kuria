class AssistantMessage < Message
  validates :ai_model, presence: true

  # Audit-only rows are persisted while hidden. The first visible content has no
  # DOM node yet, so it must append once; later content changes update normally.
  after_update_commit :broadcast_first_visible_content, if: :first_visible_content_from_pending?

  def role
    "assistant"
  end

  def append_text!(text)
    self.content += text
    save!
  end

  private
    def content_optional?
      pending? || failed?
    end

    def broadcast?
      return false if failed?
      return false if pending? && content.blank?
      return false if first_visible_content_from_pending?

      true
    end

    def first_visible_content_from_pending?
      !failed? &&
        !previously_new_record? &&
        status_before_last_save == "pending" &&
        saved_change_to_content? &&
        content_before_last_save.blank? &&
        content.present?
    end

    def broadcast_first_visible_content
      broadcast_append_to chat, target: "messages"
    end
end
