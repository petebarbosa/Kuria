class Provider::Opencode::Client
  BASE_HEADERS = {
    "Content-Type" => "application/json",
    "Accept" => "application/json"
  }.freeze

  class InvalidResponseError < StandardError; end

  def initialize(base_url:, password: nil, username: "opencode")
    @faraday_connection = Faraday.new(url: base_url) do |f|
      f.request :json
      f.response :json
      f.response :raise_error
      f.headers = BASE_HEADERS
      f.request :authorization, :basic, username, password if password.present?
    end
  end

  def create_session(title: nil, parent_id: nil)
    body = {}
    body[:title] = title if title.present?
    body[:parentID] = parent_id if parent_id.present?

    response = faraday_connection.post("/session", body)
    response.body
  end

  def send_message(session_id, content:, model: nil, format: nil, system: nil, tools: nil)
    body = {
      parts: [ { type: "text", text: content } ]
    }
    body[:model] = model if model.present?
    body[:format] = format if format.present?
    body[:system] = system if system.present?
    body[:tools] = tools if tools.present?

    response = faraday_connection.post("/session/#{session_id}/message", body)
    body = response.body

    unless body.is_a?(Hash)
      raise InvalidResponseError, "OpenCode /session/#{session_id}/message returned invalid response: expected Hash, got #{body.class}. Status: #{response.status}. Model: #{model.inspect}"
    end

    body
  end

  def send_message_async(session_id, content:, model: nil, format: nil, system: nil)
    body = {
      parts: [ { type: "text", text: content } ]
    }
    body[:model] = model if model.present?
    body[:format] = format if format.present?
    body[:system] = system if system.present?

    faraday_connection.post("/session/#{session_id}/prompt_async", body)
    true
  end

  def list_messages(session_id, limit: nil)
    params = {}
    params[:limit] = limit if limit.present?

    response = faraday_connection.get("/session/#{session_id}/message", params)
    response.body
  end

  def get_message(session_id, message_id:)
    response = faraday_connection.get("/session/#{session_id}/message/#{message_id}")
    response.body
  end

  def list_providers
    response = faraday_connection.get("/provider")
    response.body
  end

  def abort_session(session_id)
    response = faraday_connection.post("/session/#{session_id}/abort")
    response.body
  end

  def get_session(session_id)
    response = faraday_connection.get("/session/#{session_id}")
    response.body
  end

  def delete_session(session_id)
    response = faraday_connection.delete("/session/#{session_id}")
    response.body
  end

  def health
    response = faraday_connection.get("/global/health")
    response.body
  end

  private
    attr_reader :faraday_connection
end
