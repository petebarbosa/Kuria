require "test_helper"

class Family::AutoCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @enrichment_model = "openai/gpt-5-nano"
    @family.enrichment_model = @enrichment_model
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:ruby_llm).returns(@llm_provider)
  end

  test "auto-categorizes transactions" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Amazon purchase").transaction
    txn3 = create_transaction(account: @account, name: "Netflix subscription").transaction

    test_category = @family.categories.create!(name: "Test category")

    provider_response = provider_success_response([
      AutoCategorization.new(transaction_id: txn1.id, category_name: test_category.name),
      AutoCategorization.new(transaction_id: txn2.id, category_name: test_category.name),
      AutoCategorization.new(transaction_id: txn3.id, category_name: nil)
    ])

    @llm_provider.expects(:auto_categorize).with(has_entries(model: @enrichment_model)).returns(provider_response).once

    assert_difference "DataEnrichment.count", 2 do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_categorize
    end

    assert_equal test_category, txn1.reload.category
    assert_equal test_category, txn2.reload.category
    assert_nil txn3.reload.category

    # After auto-categorization, all transactions are locked and no longer enrichable
    assert_equal 0, @account.transactions.reload.enrichable(:category_id).count
  end

  test "ignores unknown ids and invalid category names and locks transactions with no matching result" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Amazon purchase").transaction
    txn3 = create_transaction(account: @account, name: "Netflix subscription").transaction

    test_category = @family.categories.create!(name: "Test category")

    # txn1 matches; txn2 carries a category name that is not in the family's
    # categories (invalid enum value -> no match); txn3 has no result at all;
    # "unknown" is an extra result for an id outside the scope.
    provider_response = provider_success_response([
      AutoCategorization.new(transaction_id: txn1.id, category_name: test_category.name),
      AutoCategorization.new(transaction_id: txn2.id, category_name: "Not a real category"),
      AutoCategorization.new(transaction_id: "unknown", category_name: test_category.name)
    ])

    @llm_provider.expects(:auto_categorize).with(has_entries(model: @enrichment_model)).returns(provider_response).once

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_categorize

    assert_equal test_category, txn1.reload.category
    assert_nil txn2.reload.category
    assert_nil txn3.reload.category

    # Existing behavior: every scoped transaction is locked even when no
    # category matched, so none remain enrichable.
    assert_equal 0, @account.transactions.reload.enrichable(:category_id).count
  end

  test "preserves safe failure when the provider returns an error response" do
    txn = create_transaction(account: @account, name: "McDonalds").transaction

    provider_response = provider_error_response(Provider::RubyLlm::Error.new("unsupported capability"))
    @llm_provider.expects(:auto_categorize).with(has_entries(model: @enrichment_model)).returns(provider_response).once

    assert_no_difference "DataEnrichment.count" do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
    end

    # No fake success and no mutation: the transaction is neither categorized
    # nor locked, so it stays enrichable for a later retry.
    assert_nil txn.reload.category
    assert_equal 1, @account.transactions.reload.enrichable(:category_id).count
  end

  private
    AutoCategorization = Provider::LlmConcept::AutoCategorization
end
