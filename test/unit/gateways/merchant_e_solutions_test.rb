require 'test_helper'

class MerchantESolutionsTest < Test::Unit::TestCase
  include CommStub

  def setup
    Base.mode = :test

    @gateway = MerchantESolutionsGateway.new(
      login: 'login',
      password: 'password'
    )

    @credit_card = credit_card
    @amount = 100

    @options = {
      order_id: '1',
      billing_address: address,
      description: 'Store Purchase'
    }

    @stored_credential_options = {
      moto_ecommerce_ind: '7',
      client_reference_number: '345892',
      recurring_pmt_num: 11,
      recurring_pmt_count: 10,
      card_on_file: 'Y',
      cit_mit_indicator: 'C101',
      account_data_source: 'Y'
    }
  end

  def test_successful_purchase
    @gateway.expects(:ssl_post).returns(successful_purchase_response)
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_instance_of Response, response
    assert_success response
    assert_equal '5547cc97dae23ea6ad1a4abd33445c91', response.authorization
    assert response.test?
  end

  def test_successful_purchase_with_stored_credentials
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @stored_credential_options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/moto_ecommerce_ind=7/, data)
      assert_match(/client_reference_number=345892/, data)
      assert_match(/recurring_pmt_num=11/, data)
      assert_match(/recurring_pmt_count=10/, data)
      assert_match(/card_on_file=Y/, data)
      assert_match(/cit_mit_indicator=C101/, data)
      assert_match(/account_data_source=Y/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_unsuccessful_purchase
    @gateway.expects(:ssl_post).returns(failed_purchase_response)
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_failure response
    assert response.test?
  end

  def test_purchase_with_long_order_id_truncates_id
    options = { order_id: 'thisislongerthan17characters' }
    @gateway.expects(:ssl_post).with(
      anything,
      all_of(
        includes('invoice_number=thisislongerthan1')
      )
    ).returns(successful_purchase_response)
    assert response = @gateway.purchase(@amount, @credit_card, options)
    assert_success response
    assert_equal 'This transaction has been approved', response.message
  end

  def test_authorization
    @gateway.expects(:ssl_post).returns(successful_authorization_response)
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert response.success?
    assert_equal '42e52603e4c83a55890fbbcfb92b8de1', response.authorization
    assert response.test?
  end

  def test_capture
    @gateway.expects(:ssl_post).returns(successful_capture_response)
    assert response = @gateway.capture(@amount, '42e52603e4c83a55890fbbcfb92b8de1', @options)
    assert response.success?
    assert_equal '42e52603e4c83a55890fbbcfb92b8de1', response.authorization
    assert response.test?
  end

  def test_refund
    @gateway.expects(:ssl_post).returns(successful_refund_response)
    assert_success @gateway.refund(@amount, '0a5ca4662ac034a59595acb61e8da025', @options)
  end

  def test_credit
    @gateway.expects(:ssl_post).returns(successful_refund_response)
    assert_success @gateway.credit(@amount, @credit_card, @options)
  end

  def test_void
    @gateway.expects(:ssl_post).returns(successful_void_response)
    assert response = @gateway.void('42e52603e4c83a55890fbbcfb92b8de1')
    assert response.success?
    assert_equal '1b08845c6dee3fa1a73fee2a009d33a7', response.authorization
    assert response.test?
  end

  def test_unstore
    @gateway.expects(:ssl_post).returns(successful_unstore_response)
    assert response = @gateway.unstore('ae641b57b19b3bb89faab44191479872')
    assert response.success?
    assert_equal 'd79410c91b4b31ba99f5a90558565df9', response.authorization
    assert response.test?
  end

  def test_successful_verify
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.verify(@credit_card, { store_card: 'y' })
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/transaction_type=A/, data)
      assert_match(/store_card=y/, data)
      assert_match(/card_number=#{@credit_card.number}/, data)
    end.respond_with(successful_verify_response)
    assert_success response
    assert_equal 'Card Ok', response.message
  end

  def test_successful_avs_check
    @gateway.expects(:ssl_post).returns(successful_purchase_response + '&avs_result=Y')
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal response.avs_result['code'], 'Y'
    assert_equal response.avs_result['message'], 'Street address and 5-digit postal code match.'
    assert_equal response.avs_result['street_match'], 'Y'
    assert_equal response.avs_result['postal_match'], 'Y'
  end

  def test_unsuccessful_avs_check_with_bad_street_address
    @gateway.expects(:ssl_post).returns(successful_purchase_response + '&avs_result=Z')
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal response.avs_result['code'], 'Z'
    assert_equal response.avs_result['message'], 'Street address does not match, but 5-digit postal code matches.'
    assert_equal response.avs_result['street_match'], 'N'
    assert_equal response.avs_result['postal_match'], 'Y'
  end

  def test_unsuccessful_avs_check_with_bad_zip
    @gateway.expects(:ssl_post).returns(successful_purchase_response + '&avs_result=A')
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal response.avs_result['code'], 'A'
    assert_equal response.avs_result['message'], 'Street address matches, but postal code does not match.'
    assert_equal response.avs_result['street_match'], 'Y'
    assert_equal response.avs_result['postal_match'], 'N'
  end

  def test_successful_cvv_check
    @gateway.expects(:ssl_post).returns(successful_purchase_response + '&cvv2_result=M')
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal response.cvv_result['code'], 'M'
    assert_equal response.cvv_result['message'], 'CVV matches'
  end

  def test_unsuccessful_cvv_check
    @gateway.expects(:ssl_post).returns(failed_purchase_response + '&cvv2_result=N')
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal response.cvv_result['code'], 'N'
    assert_equal response.cvv_result['message'], 'CVV does not match'
  end

  def test_visa_3dsecure_params_submitted
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge({ xid: '1', cavv: '2' }))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/xid=1/, data)
      assert_match(/cavv=2/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_mastercard_3dsecure_params_submitted
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge({ ucaf_collection_ind: '1', ucaf_auth_data: '2' }))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/ucaf_collection_ind=1/, data)
      assert_match(/ucaf_auth_data=2/, data)
    end.respond_with(successful_purchase_response)
  end

  # ------------------------------------------------------------------
  # Level II / Level III  (MeS Trident certification)
  # ------------------------------------------------------------------

  def level_2_options
    {
      tax_amount: '10.35',
      rctl_commercial_card: 'y',
      ship_to_zip: '80542'
    }
  end

  def test_level_2_fields_submitted_on_purchase
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(level_2_options))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/tax_amount=10\.35/, data)
      assert_match(/rctl_commercial_card=y/, data)
      assert_match(/ship_to_zip=80542/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_level_2_fields_submitted_on_authorize
    stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card, @options.merge(level_2_options))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/transaction_type=P/, data)
      assert_match(/tax_amount=10\.35/, data)
      assert_match(/rctl_commercial_card=y/, data)
      assert_match(/ship_to_zip=80542/, data)
    end.respond_with(successful_authorization_response)
  end

  def test_level_2_fields_submitted_on_capture
    stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, 'transaction-id-1', level_2_options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/transaction_type=S/, data)
      assert_match(/transaction_id=transaction-id-1/, data)
      assert_match(/tax_amount=10\.35/, data)
      assert_match(/ship_to_zip=80542/, data)
    end.respond_with(successful_capture_response)
  end

  def test_level_2_and_3_fields_omitted_when_not_supplied
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_no_match(/tax_amount=/, data)
      assert_no_match(/rctl_commercial_card=/, data)
      assert_no_match(/ship_to_zip=/, data)
      assert_no_match(/line_item_count=/, data)
      assert_no_match(/visa_line_item=/, data)
      assert_no_match(/mc_line_item=/, data)
      assert_no_match(/amex_line_item=/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_level_3_header_fields_submitted
    l3 = {
      line_item_count: '1',
      merchant_tax_id: '123456789',
      customer_tax_id: '987654321',
      summary_commodity_code: '1234',
      discount_amount: '0.50',
      ship_from_zip: '99201',
      dest_country_code: '840',
      vat_invoice_number: '123456789',
      order_date: '260714',
      alt_tax_amount_indicator: 'N',
      requester_name: 'John+Smith',
      cardholder_reference_number: '123456789'
    }

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(l3))
    end.check_request do |_method, _endpoint, data, _headers|
      l3.each_key { |k| assert_match(/#{k}=/, data, "expected #{k} in request") }
      assert_match(/merchant_tax_id=123456789/, data)
      assert_match(/dest_country_code=840/, data)
      assert_match(/order_date=260714/, data)
    end.respond_with(successful_purchase_response)
  end

  # Zero-valued L3 amounts must reach the gateway rather than being treated as
  # omissions -- the cert script sends shipping_amount=0.00 / duty_amount=0.00 /
  # vat_amount=0.00. Empty#empty? reports numeric 0 as absent, so the adapter must
  # not use it for these fields.
  #
  # This exercises the DIRECT Ruby-caller path. Requests arriving via the TokenEx
  # wrapper are stringified upstream ("0.00"), so they would pass either way; this
  # test covers callers that hand the adapter a genuine numeric 0.
  def test_level_3_zero_amounts_are_preserved
    zeros = {
      shipping_amount: 0,
      duty_amount: 0.0,
      vat_amount: '0.00',
      alt_tax_amount: 0
    }

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(zeros))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/shipping_amount=0/, data)
      assert_match(/duty_amount=0\.0/, data)
      assert_match(/vat_amount=0\.00/, data)
      assert_match(/alt_tax_amount=0/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_level_3_blank_strings_are_omitted
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(duty_amount: '', ship_from_zip: '   '))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_no_match(/duty_amount=/, data)
      assert_no_match(/ship_from_zip=/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_visa_line_item_string_is_passed_through_untouched
    composite = '999999<|>carbon dioxide equipment<|>ABC123<|>1<|>EA<|>4.75<|>0.00<|>0<|>0.50<|>4.25<|>D'

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(visa_line_item: composite))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/visa_line_item=#{Regexp.escape(composite)}/, CGI.unescape(data))
    end.respond_with(successful_purchase_response)
  end

  def test_visa_line_item_built_from_hash_in_correct_order
    item = {
      commodity_code: '999999',
      description: 'carbon dioxide equipment',
      product_code: 'ABC123',
      quantity: '1',
      unit_of_measure: 'EA',
      unit_cost: '4.75',
      vat_tax_amount: '0.00',
      vat_tax_rate: '0',
      discount_per_line_item: '0.50',
      line_item_total: '4.25',
      debit_or_credit_indicator: 'D'
    }

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(visa_line_item: item))
    end.check_request do |_method, _endpoint, data, _headers|
      expected = '999999<|>carbon dioxide equipment<|>ABC123<|>1<|>EA<|>4.75<|>0.00<|>0<|>0.50<|>4.25<|>D'
      assert_match(/visa_line_item=#{Regexp.escape(expected)}/, CGI.unescape(data))
    end.respond_with(successful_purchase_response)
  end

  def test_mastercard_line_item_built_from_hash_in_correct_order
    item = {
      description: 'Test_Item',
      product_code: 'OU812',
      quantity: '1',
      unit_of_measure: 'EA',
      alternate_tax_identifier: '000000000000000',
      tax_rate_applied: '10.0',
      tax_type_applied: 'STAT',
      tax_amount: '0.55',
      discount_indicator: 'Y',
      net_or_gross_indicator: 'N',
      extended_item_amount: '5.45',
      debit_or_credit_indicator: 'D',
      discount_amount: '0.50'
    }

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(mc_line_item: item))
    end.check_request do |_method, _endpoint, data, _headers|
      expected = 'Test_Item<|>OU812<|>1<|>EA<|>000000000000000<|>10.0<|>STAT<|>0.55<|>Y<|>N<|>5.45<|>D<|>0.50'
      assert_match(/mc_line_item=#{Regexp.escape(expected)}/, CGI.unescape(data))
    end.respond_with(successful_purchase_response)
  end

  # Amex sub-fields per cert script cell H29: Item Descriptor | Quantity | Unit Cost.
  # The third field is Unit Cost, NOT Line Item Total -- Visa carries both, Amex
  # only has unit cost.
  def test_amex_line_item_built_from_hash_in_correct_order
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(
        @amount, @credit_card,
        @options.merge(amex_line_item: { description: 'SAW', quantity: '1', unit_cost: '4.65' })
      )
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/amex_line_item=#{Regexp.escape('SAW<|>1<|>4.65')}/, CGI.unescape(data))
    end.respond_with(successful_purchase_response)
  end

  # Guard the Amex third-field semantics. With quantity 1 (as in the cert example)
  # unit cost and line total are numerically identical, so a mis-named third field
  # is invisible. quantity 3 makes them distinguishable.
  def test_amex_line_item_third_field_is_unit_cost_not_line_total
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(
        @amount, @credit_card,
        @options.merge(amex_line_item: { description: 'SAW', quantity: '3', unit_cost: '4.65' })
      )
    end.check_request do |_method, _endpoint, data, _headers|
      decoded = CGI.unescape(data)
      assert_match(/amex_line_item=#{Regexp.escape('SAW<|>3<|>4.65')}/, decoded)
      # 13.95 would be the extended/line total -- it must not appear
      assert_no_match(/13\.95/, decoded)
    end.respond_with(successful_purchase_response)
  end

  # Visa DOES carry both unit cost (field 6) and line item total (field 10);
  # this pins those two positions so they cannot be transposed.
  def test_visa_line_item_distinguishes_unit_cost_from_line_item_total
    item = {
      commodity_code: '999999', description: 'widget', product_code: 'ABC123',
      quantity: '3', unit_of_measure: 'EA', unit_cost: '4.75',
      vat_tax_amount: '0.00', vat_tax_rate: '0', discount_per_line_item: '0.00',
      line_item_total: '14.25', debit_or_credit_indicator: 'D'
    }

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(visa_line_item: item))
    end.check_request do |_method, _endpoint, data, _headers|
      expected = '999999<|>widget<|>ABC123<|>3<|>EA<|>4.75<|>0.00<|>0<|>0.00<|>14.25<|>D'
      assert_match(/visa_line_item=#{Regexp.escape(expected)}/, CGI.unescape(data))
    end.respond_with(successful_purchase_response)
  end

  def test_line_item_hash_accepts_string_keys
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(
        @amount, @credit_card,
        @options.merge(amex_line_item: { 'description' => 'SAW', 'quantity' => '1', 'unit_cost' => '4.65' })
      )
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/amex_line_item=#{Regexp.escape('SAW<|>1<|>4.65')}/, CGI.unescape(data))
    end.respond_with(successful_purchase_response)
  end

  # ------------------------------------------------------------------
  # Subsequent COF/CIT -- transaction_id on the purchase/authorize path
  # ------------------------------------------------------------------

  def test_transaction_id_submitted_on_purchase_for_subsequent_cof
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @stored_credential_options.merge(transaction_id: 'prior-txn-99'))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/transaction_type=D/, data)
      assert_match(/transaction_id=prior-txn-99/, data)
      assert_match(/card_on_file=Y/, data)
      assert_match(/cit_mit_indicator=C101/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_transaction_id_submitted_on_authorize_for_subsequent_cof
    stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card, @stored_credential_options.merge(transaction_id: 'prior-txn-99'))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/transaction_id=prior-txn-99/, data)
    end.respond_with(successful_authorization_response)
  end

  def test_transaction_id_omitted_from_purchase_when_not_supplied
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @stored_credential_options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_no_match(/transaction_id=/, data)
    end.respond_with(successful_purchase_response)
  end

  # ------------------------------------------------------------------
  # merchant_initiated (MIT) -- not in the certification script, which only
  # exercises C101 (cardholder-initiated). Required for interchange.
  # ------------------------------------------------------------------

  def test_merchant_initiated_submitted_on_purchase
    mit = @stored_credential_options.merge(
      cit_mit_indicator: 'M102', merchant_initiated: 'Y', transaction_id: 'prior-txn-99'
    )
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, mit)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/merchant_initiated=Y/, data)
      assert_match(/cit_mit_indicator=M102/, data)
      assert_match(/card_on_file=Y/, data)
      assert_match(/account_data_source=Y/, data)
      assert_match(/transaction_id=prior-txn-99/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_merchant_initiated_submitted_on_authorize
    stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card, @stored_credential_options.merge(merchant_initiated: 'Y'))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/merchant_initiated=Y/, data)
    end.respond_with(successful_authorization_response)
  end

  def test_merchant_initiated_omitted_when_not_supplied
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @stored_credential_options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_no_match(/merchant_initiated/, data)
    end.respond_with(successful_purchase_response)
  end

  # ------------------------------------------------------------------
  # options[:customer] -> client_reference_number on authorize/purchase.
  # The other six entry points already did this; these two did not.
  # ------------------------------------------------------------------

  def test_customer_maps_to_client_reference_number_on_purchase
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge(customer: 'CUST-4711'))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/client_reference_number=CUST-4711/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_customer_maps_to_client_reference_number_on_authorize
    stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card, @options.merge(customer: 'CUST-4711'))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/client_reference_number=CUST-4711/, data)
    end.respond_with(successful_authorization_response)
  end

  # An explicitly supplied client_reference_number outranks the :customer alias.
  def test_explicit_client_reference_number_wins_over_customer
    opts = @options.merge(customer: 'CUST-4711', client_reference_number: '345892')
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, opts)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/client_reference_number=345892/, data)
      assert_no_match(/CUST-4711/, data)
    end.respond_with(successful_purchase_response)
  end

  def test_client_reference_number_omitted_when_neither_supplied
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_no_match(/client_reference_number/, data)
    end.respond_with(successful_purchase_response)
  end

  # ------------------------------------------------------------------
  # Certification payload regression guards
  # Reproduce the exact param sets from the MeS Trident test script so a
  # future refactor cannot silently drop a required certification field.
  # ------------------------------------------------------------------

  def test_certification_level_2_payload
    opts = @options.merge(
      order_id: '1234567890',
      tax_amount: '10.35',
      rctl_commercial_card: 'y',
      ship_to_zip: '80542',
      moto_ecommerce_ind: '7',
      card_on_file: 'y',
      cit_mit_indicator: 'C101',
      account_data_source: 'y'
    )

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(11_035, @credit_card, opts)
    end.check_request do |_method, _endpoint, data, _headers|
      %w[
        transaction_type=D transaction_amount=110.35 tax_amount=10.35
        rctl_commercial_card=y ship_to_zip=80542 moto_ecommerce_ind=7
        card_on_file=y cit_mit_indicator=C101 account_data_source=y
        invoice_number=1234567890
      ].each { |p| assert_match(/#{Regexp.escape(p)}/, CGI.unescape(data), "missing #{p}") }
    end.respond_with(successful_purchase_response)
  end

  def test_certification_visa_level_3_payload
    opts = @options.merge(
      order_id: '1234567890',
      tax_amount: '0.75', line_item_count: '1',
      merchant_tax_id: '123456789', customer_tax_id: '987654321',
      summary_commodity_code: '1234', discount_amount: '0.50',
      shipping_amount: '0.00', duty_amount: '0.00',
      ship_to_zip: '85201', ship_from_zip: '99201',
      dest_country_code: '840', vat_invoice_number: '123456789',
      order_date: '260714', vat_amount: '0.00',
      rctl_commercial_card: 'y', moto_ecommerce_ind: '7',
      visa_line_item: '999999<|>carbon dioxide equipment<|>ABC123<|>1<|>EA<|>4.75<|>0.00<|>0<|>0.50<|>4.25<|>D'
    )

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(500, @credit_card, opts)
    end.check_request do |_method, _endpoint, data, _headers|
      decoded = CGI.unescape(data)
      %w[
        transaction_type=D transaction_amount=5.00 tax_amount=0.75
        line_item_count=1 merchant_tax_id=123456789 customer_tax_id=987654321
        summary_commodity_code=1234 discount_amount=0.50 shipping_amount=0.00
        duty_amount=0.00 ship_to_zip=85201 ship_from_zip=99201
        dest_country_code=840 vat_invoice_number=123456789 order_date=260714
        vat_amount=0.00 rctl_commercial_card=y
      ].each { |p| assert_match(/#{Regexp.escape(p)}/, decoded, "missing #{p}") }
      assert_match(
        /visa_line_item=#{Regexp.escape('999999<|>carbon dioxide equipment<|>ABC123<|>1<|>EA<|>4.75<|>0.00<|>0<|>0.50<|>4.25<|>D')}/,
        decoded
      )
    end.respond_with(successful_purchase_response)
  end

  def test_certification_mastercard_level_3_payload
    opts = @options.merge(
      order_id: '1234567890',
      tax_amount: '0.55', line_item_count: '1',
      merchant_tax_id: '123456789', customer_tax_id: '987654321',
      duty_amount: '0.00', ship_to_zip: '85201', ship_from_zip: '99212',
      dest_country_code: '840', alt_tax_amount: '0.00',
      alt_tax_amount_indicator: 'N',
      rctl_commercial_card: 'y', moto_ecommerce_ind: '7',
      mc_line_item: 'Test_Item<|>OU812<|>1<|>EA<|>000000000000000<|>10.0<|>STAT<|>0.55<|>Y<|>N<|>5.45<|>D<|>0.50'
    )

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(600, @credit_card, opts)
    end.check_request do |_method, _endpoint, data, _headers|
      decoded = CGI.unescape(data)
      %w[
        transaction_amount=6.00 tax_amount=0.55 alt_tax_amount=0.00
        alt_tax_amount_indicator=N ship_from_zip=99212
      ].each { |p| assert_match(/#{Regexp.escape(p)}/, decoded, "missing #{p}") }
      assert_match(
        /mc_line_item=#{Regexp.escape('Test_Item<|>OU812<|>1<|>EA<|>000000000000000<|>10.0<|>STAT<|>0.55<|>Y<|>N<|>5.45<|>D<|>0.50')}/,
        decoded
      )
    end.respond_with(successful_purchase_response)
  end

  def test_certification_amex_level_3_payload
    opts = @options.merge(
      order_id: '1234567890',
      tax_amount: '0.35', line_item_count: '1',
      requester_name: 'John+Smith',
      cardholder_reference_number: '123456789',
      ship_to_zip: '55555', vat_amount: '0.00',
      rctl_commercial_card: 'y', moto_ecommerce_ind: '7',
      amex_line_item: 'SAW<|>1<|>4.65'
    )

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(500, @credit_card, opts)
    end.check_request do |_method, _endpoint, data, _headers|
      decoded = CGI.unescape(data)
      %w[
        transaction_amount=5.00 tax_amount=0.35 line_item_count=1
        cardholder_reference_number=123456789 ship_to_zip=55555 vat_amount=0.00
      ].each { |p| assert_match(/#{Regexp.escape(p)}/, decoded, "missing #{p}") }
      assert_match(/requester_name=John/, decoded)
      assert_match(/amex_line_item=#{Regexp.escape('SAW<|>1<|>4.65')}/, decoded)
    end.respond_with(successful_purchase_response)
  end

  def test_supported_countries
    assert_equal ['US'], MerchantESolutionsGateway.supported_countries
  end

  def test_supported_card_types
    assert_equal %i[visa master american_express discover jcb], MerchantESolutionsGateway.supported_cardtypes
  end

  def test_scrub
    assert @gateway.supports_scrubbing?
    assert_equal @gateway.scrub(pre_scrubbed), post_scrubbed
  end

  private

  def successful_purchase_response
    'transaction_id=5547cc97dae23ea6ad1a4abd33445c91&error_code=000&auth_response_text=Exact Match&auth_code=12345A'
  end

  def successful_authorization_response
    'transaction_id=42e52603e4c83a55890fbbcfb92b8de1&error_code=000&auth_response_text=Exact Match&auth_code=12345A'
  end

  def successful_refund_response
    'transaction_id=0a5ca4662ac034a59595acb61e8da025&error_code=000&auth_response_text=Credit Approved'
  end

  def successful_void_response
    'transaction_id=1b08845c6dee3fa1a73fee2a009d33a7&error_code=000&auth_response_text=Void Request Accepted'
  end

  def successful_capture_response
    'transaction_id=42e52603e4c83a55890fbbcfb92b8de1&error_code=000&auth_response_text=Settle Request Accepted'
  end

  def successful_store_response
    'transaction_id=ae641b57b19b3bb89faab44191479872&error_code=000&auth_response_text=Card Data Stored'
  end

  def successful_unstore_response
    'transaction_id=d79410c91b4b31ba99f5a90558565df9&error_code=000&auth_response_text=Stored Card Data Deleted'
  end

  def successful_verify_response
    'transaction_id=a5ef059bff7a3f75ac2398eea4cc73cd&error_code=085&auth_response_text=Card Ok&avs_result=0&cvv2_result=M&auth_code=T1933H'
  end

  def failed_purchase_response
    'transaction_id=error&error_code=101&auth_response_text=Invalid%20I%20or%20Key%20Incomplete%20Request'
  end

  def pre_scrubbed
    <<-TRANSCRIPT
    "profile_id=94100010518900000029&profile_key=YvKeIpxLxpJoKRKkJjMOpqmGkwUCBBEO&transaction_type=D&invoice_number=123&card_number=4111111111111111&cvv2=123&card_exp_date=0919&cardholder_street_address=123%2BState%2BStreet&cardholder_zip=55555&transaction_amount=1.00"
    "transaction_id=3dfdc828adf032d589111ff45a7087fc&error_code=000&auth_response_text=Exact Match&avs_result=Y&cvv2_result=M&auth_code=T4797H"
    TRANSCRIPT
  end

  def post_scrubbed
    <<-TRANSCRIPT
    "profile_id=94100010518900000029&profile_key=[FILTERED]&transaction_type=D&invoice_number=123&card_number=[FILTERED]&cvv2=[FILTERED]&card_exp_date=0919&cardholder_street_address=123%2BState%2BStreet&cardholder_zip=55555&transaction_amount=1.00"
    "transaction_id=3dfdc828adf032d589111ff45a7087fc&error_code=000&auth_response_text=Exact Match&avs_result=Y&cvv2_result=M&auth_code=T4797H"
    TRANSCRIPT
  end
end
