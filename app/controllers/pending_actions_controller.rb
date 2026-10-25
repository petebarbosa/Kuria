class PendingActionsController < ApplicationController
  def confirm
    action = PendingAction.confirm_and_execute!(
      id: params[:id],
      confirmed_by: Current.user,
      family: Current.family
    )

    if action
      execution_succeeded = action.audit_result["success"] == true

      render json: {
        status: "confirmed",
        execution_status: action.audit_result["execution_status"] || (execution_succeeded ? "succeeded" : "failed"),
        pending_action_id: action.id,
        audit_result: action.audit_result
      }, status: execution_succeeded ? :ok : :unprocessable_entity
    else
      pending = PendingAction.where(family: Current.family).find_by(id: params[:id])
      return head :not_found unless pending

      render json: {
        status: "rejected",
        pending_action_id: pending.id,
        reason: pending.audit_result&.dig("last_confirmation_attempt", "reason") || "rejected",
        execution_status: pending.audit_result&.dig("execution_status")
      }, status: :unprocessable_entity
    end
  end
end
