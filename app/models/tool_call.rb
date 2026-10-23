class ToolCall < ApplicationRecord
  # Audit payloads carry model arguments and financial tool results. ActiveRecord
  # formats SQL debug binds with the base inspection filter
  # (ActiveRecord::LogSubscriber#filter), so declare the sensitive columns on the
  # base list; ToolCall inherits them for #inspect as well. The values remain in
  # the database; only log/inspection rendering is masked.
  ActiveRecord::Base.filter_attributes |= %w[function_arguments function_result]

  belongs_to :message
end
