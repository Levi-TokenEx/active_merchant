require 'test_helper'

class UsioAchTest < Test::Unit::TestCase
  include CommStub

  def setup
    @gateway = UsioAchGateway.new(merchant_id: 'merchant_id', login: 'login', password: 'password')
    @check = check
    @amount = 100

    @options = {
      order_id: '1',
      billing_address: address
    }
  end

  def test_initialize_requires_credentials
    assert_raise(ArgumentError) { UsioAchGateway.new }
    assert UsioAchGateway.new(merchant_id: 'x', login: 'y', password: 'z')
  end

  def test_successful_purchase
    response = stub_comms do
      @gateway.purchase(@amount, @check, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal 'Debit', request['TransactionType']
      assert_equal '1.00', request['Amount']
      assert_equal @check.routing_number, request['RoutingNumber']
      assert_equal @check.account_number, request['AccountNumber']
    end.respond_with(successful_purchase_response)

    assert_success response
    assert_equal 'ACHCONF123', response.authorization
  end

  def test_failed_purchase
    response = stub_comms do
      @gateway.purchase(@amount, @check, @options)
    end.respond_with(failed_purchase_response)

    assert_failure response
    assert_equal 'Invalid account', response.message
  end

  def test_successful_refund
    response = stub_comms do
      @gateway.refund(@amount, 'ACHCONF123', @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal 'ACHCONF123', request['ConfirmationID']
    end.respond_with(successful_void_response)

    assert_success response
  end

  def test_failed_refund
    response = stub_comms do
      @gateway.refund(@amount, 'bogus', @options)
    end.respond_with(failed_void_response)

    assert_failure response
  end

  def test_successful_void
    response = stub_comms do
      @gateway.void('ACHCONF123')
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal 'ACHCONF123', request['ConfirmationID']
    end.respond_with(successful_void_response)

    assert_success response
  end

  def test_failed_void
    response = stub_comms do
      @gateway.void('bogus')
    end.respond_with(failed_void_response)

    assert_failure response
  end

  def test_purchase_with_stored_confirmation_id_source
    stub_comms do
      @gateway.purchase(@amount, 'ACHCONF123', @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal 'ACHCONF123', request['ConfirmationID']
    end.respond_with(successful_purchase_response)
  end

  def test_supports_scrubbing
    assert @gateway.supports_scrubbing?
  end

  def test_scrub
    assert_equal post_scrubbed, @gateway.scrub(pre_scrubbed)
  end

  private

  def pre_scrubbed
    '
      {"TransactionType":"Debit","Amount":"1.00","RoutingNumber":"244183602","AccountNumber":"15378535","AccountType":"checking","MerchantID":"merchant_id","Login":"login","Password":"password"}
    '
  end

  def post_scrubbed
    '
      {"TransactionType":"Debit","Amount":"1.00","RoutingNumber":"[FILTERED]","AccountNumber":"[FILTERED]","AccountType":"checking","MerchantID":"merchant_id","Login":"login","Password":"[FILTERED]"}
    '
  end

  def successful_purchase_response
    '{"Status":"success","Message":"Accepted","ConfirmationID":"ACHCONF123"}'
  end

  def failed_purchase_response
    '{"Status":"failure","Message":"Invalid account","ConfirmationID":null}'
  end

  def successful_void_response
    '{"Status":"success","Message":"Voided","ConfirmationID":"ACHCONF123"}'
  end

  def failed_void_response
    '{"Status":"failure","Message":"Void failed","ConfirmationID":null}'
  end
end
