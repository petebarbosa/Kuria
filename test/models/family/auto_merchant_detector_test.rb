require "test_helper"

class Family::AutoMerchantDetectorTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @enrichment_model = "openai/gpt-5-nano"
    @family.enrichment_model = @enrichment_model
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:ruby_llm).returns(@llm_provider)
  end

  test "auto detects transaction merchants" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Chipotle").transaction
    txn3 = create_transaction(account: @account, name: "generic").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn1.id, business_name: "McDonalds", business_url: "mcdonalds.com"),
      AutoDetectedMerchant.new(transaction_id: txn2.id, business_name: "Chipotle", business_url: "chipotle.com"),
      AutoDetectedMerchant.new(transaction_id: txn3.id, business_name: nil, business_url: nil)
    ])

    @llm_provider.expects(:auto_detect_merchants).with(has_entries(model: @enrichment_model)).returns(provider_response).once

    assert_difference "DataEnrichment.count", 2 do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_detect
    end

    assert_equal "McDonalds", txn1.reload.merchant.name
    assert_equal "Chipotle", txn2.reload.merchant.name
    assert_equal "https://logo.synthfinance.com/mcdonalds.com", txn1.reload.merchant.logo_url
    assert_equal "https://logo.synthfinance.com/chipotle.com", txn2.reload.merchant.logo_url
    assert_nil txn3.reload.merchant

    # After auto-detection, all transactions are locked and no longer enrichable
    assert_equal 0, @account.transactions.reload.enrichable(:merchant_id).count
  end

  test "ignores unknown ids and locks transactions with no matching result" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Chipotle").transaction
    txn3 = create_transaction(account: @account, name: "generic").transaction

    # txn1 matches; txn2 has no result at all; "unknown" is an extra result for
    # an id outside the scope.
    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn1.id, business_name: "McDonalds", business_url: "mcdonalds.com"),
      AutoDetectedMerchant.new(transaction_id: "unknown", business_name: "Ghost", business_url: "ghost.com")
    ])

    @llm_provider.expects(:auto_detect_merchants).with(has_entries(model: @enrichment_model)).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_detect

    assert_equal "McDonalds", txn1.reload.merchant.name
    assert_nil txn2.reload.merchant
    assert_nil txn3.reload.merchant

    # Existing behavior: every scoped transaction is locked even when no
    # merchant matched, so none remain enrichable.
    assert_equal 0, @account.transactions.reload.enrichable(:merchant_id).count
  end

  test "preserves safe failure when the provider returns an error response" do
    txn = create_transaction(account: @account, name: "McDonalds").transaction

    provider_response = provider_error_response(Provider::RubyLlm::Error.new("model unavailable"))
    @llm_provider.expects(:auto_detect_merchants).with(has_entries(model: @enrichment_model)).returns(provider_response).once

    assert_no_difference "DataEnrichment.count" do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    # No fake success and no mutation: the transaction is neither assigned a
    # merchant nor locked, so it stays enrichable for a later retry.
    assert_nil txn.reload.merchant
    assert_equal 1, @account.transactions.reload.enrichable(:merchant_id).count
  end

  private
    AutoDetectedMerchant = Provider::LlmConcept::AutoDetectedMerchant
end
