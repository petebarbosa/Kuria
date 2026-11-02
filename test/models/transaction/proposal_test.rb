require "test_helper"

class Transaction::ProposalTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = @family.accounts.create!(
      name: "Proposal account",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )
  end

  test "prepares a pending action without mutating financial data" do
    params = {
      "account_id" => @account.id,
      "date" => Date.current.to_s,
      "name" => "Coffee",
      "amount" => "4.50"
    }
    pending = nil

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      assert_difference("PendingAction.count", 1) do
        pending = Transaction::Proposal.prepare!(
          family: @family,
          params: params,
          user: @user,
          idempotency_key: "provider-call-1"
        )
      end
    end

    assert_kind_of PendingAction, pending
    assert pending.persisted?
    assert_equal "create_transaction", pending.action_type
    assert_equal @family.id, pending.family_id
    assert_equal @user.id, pending.user_id
    assert_equal params, pending.params
  end

  test "normalizes symbol keys without mutating the caller params" do
    params = {
      account_id: @account.id,
      date: Date.current.to_s,
      name: "Coffee",
      amount: "4.50",
      user_id: @user.id,
      idempotency_key: "caller-owned"
    }
    original = params.dup

    pending = Transaction::Proposal.prepare!(family: @family, params: params, user: @user)

    assert_equal original, params
    assert_equal original.keys.sort, params.keys.sort
    assert_equal @account.id, pending.params.fetch("account_id")
    assert_equal "Coffee", pending.params.fetch("name")
    refute pending.params.key?("user_id")
    refute pending.params.key?("idempotency_key")
    refute pending.params.key?(:user_id)
    refute pending.params.key?(:idempotency_key)
  end

  test "applies currency, kind, and BigDecimal defaults to the preview only" do
    params = {
      "account_id" => @account.id,
      "date" => Date.current.to_s,
      "name" => "Rent",
      "amount" => "1000.00"
    }

    pending = Transaction::Proposal.prepare!(family: @family, params: params)

    assert_equal @family.currency, pending.preview.fetch("currency")
    assert_equal "standard", pending.preview.fetch("kind")
    assert_equal "1000.0", pending.preview.fetch("amount")
    assert_equal "1000.00", pending.params.fetch("amount")
    refute pending.params.key?("currency")
    refute pending.params.key?("kind")
  end

  test "scopes the account lookup to the trusted family" do
    other_account = families(:empty).accounts.create!(
      name: "Foreign account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    params = {
      "account_id" => other_account.id,
      "date" => Date.current.to_s,
      "name" => "Foreign",
      "amount" => "10.00"
    }

    assert_no_difference("PendingAction.count") do
      assert_raises(ActiveRecord::RecordNotFound) do
        Transaction::Proposal.prepare!(family: @family, params: params)
      end
    end
  end

  test "keeps user family validation with PendingAction" do
    params = {
      "account_id" => @account.id,
      "date" => Date.current.to_s,
      "name" => "Wrong user",
      "amount" => "10.00"
    }

    assert_no_difference("PendingAction.count") do
      assert_raises(ActiveRecord::RecordNotFound) do
        Transaction::Proposal.prepare!(
          family: @family,
          params: params,
          user: users(:empty)
        )
      end
    end
  end

  test "returns the original proposal for a retried idempotency key" do
    params = {
      "account_id" => @account.id,
      "date" => Date.current.to_s,
      "name" => "Retry",
      "amount" => "10.00"
    }

    first = Transaction::Proposal.prepare!(
      family: @family,
      params: params,
      user: @user,
      idempotency_key: "retry-key"
    )
    second = nil

    assert_no_difference("PendingAction.count") do
      second = Transaction::Proposal.prepare!(
        family: @family,
        params: params,
        user: @user,
        idempotency_key: "retry-key"
      )
    end

    assert_equal first.id, second.id
    assert_equal first.preview, second.preview
  end

  test "supports the legacy call without a user" do
    params = {
      "account_id" => @account.id,
      "date" => Date.current.to_s,
      "name" => "Legacy",
      "amount" => "10.00"
    }

    pending = Transaction::Proposal.prepare!(family: @family, params: params)

    assert pending.persisted?
    assert_nil pending.user_id
  end
end
