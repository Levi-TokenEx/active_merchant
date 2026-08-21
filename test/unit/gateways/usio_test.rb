require 'test_helper'

class UsioTest < Test::Unit::TestCase
  include CommStub

  def setup
    @gateway = UsioGateway.new(merchant_id: 'merchant_id', login: 'login', password: 'password')
    @credit_card = credit_card
    @declined_card = credit_card('4000300011112220')
    @network_token = network_tokenization_credit_card
    @amount = 100

    @options = {
      order_id: '1',
      billing_address: address
    }
  end

  def test_initialize_requires_credentials
    assert_raise(ArgumentError) { UsioGateway.new }
    assert_raise(ArgumentError) { UsioGateway.new(merchant_id: 'x') }
    assert UsioGateway.new(merchant_id: 'x', login: 'y', password: 'z')
  end

  def test_successful_purchase
    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal false, request['AuthOnly']
      assert_equal '1.00', request['Amount']
      assert_equal @credit_card.number, request['CardNumber']
      assert_equal 'merchant_id', request['MerchantID']
    end.respond_with(successful_purchase_response)

    assert_success response
    assert_equal 'CONF123', response.authorization
    assert response.test?
  end

  def test_failed_purchase
    response = stub_comms do
      @gateway.purchase(@amount, @declined_card, @options)
    end.respond_with(failed_purchase_response)

    assert_failure response
    assert_equal 'Declined', response.message
  end

  def test_successful_authorize
    response = stub_comms do
      @gateway.authorize(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal true, request['AuthOnly']
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'CONF124', response.authorization
  end

  def test_failed_authorize
    response = stub_comms do
      @gateway.authorize(@amount, @declined_card, @options)
    end.respond_with(failed_authorize_response)

    assert_failure response
  end

  def test_successful_capture
    response = stub_comms do
      @gateway.capture(@amount, 'CONF124', @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal 'CONF124', request['ConfirmationID']
    end.respond_with(successful_capture_response)

    assert_success response
    assert_equal 'CONF124', response.authorization
  end

  def test_failed_capture
    response = stub_comms do
      @gateway.capture(@amount, 'bogus', @options)
    end.respond_with(failed_capture_response)

    assert_failure response
  end

  def test_successful_refund
    response = stub_comms do
      @gateway.refund(@amount, 'CONF123', @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal 'CONF123', request['ConfirmationID']
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
      @gateway.void('CONF124')
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal 'CONF124', request['ConfirmationID']
      assert_nil request['Amount']
    end.respond_with(successful_void_response)

    assert_success response
  end

  def test_failed_void
    response = stub_comms do
      @gateway.void('bogus')
    end.respond_with(failed_void_response)

    assert_failure response
  end

  def test_successful_verify_uses_one_dollar_not_zero_dollar_auth
    response = stub_comms do
      @gateway.verify(@credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal '1.00', request['Amount'] if request['AuthOnly'] == true
    end.respond_with(successful_authorize_response, successful_void_response)

    assert_success response
  end

  def test_network_tokenization_credit_card_maps_cryptogram_to_secure3d
    stub_comms do
      @gateway.purchase(@amount, @network_token, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal @network_token.number, request['CardNumber']
      assert_equal @network_token.payment_cryptogram, request['secure3D']
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
      {"AuthOnly":false,"Amount":"1.00","CardNumber":"4242424242424242","ExpDate":"0928","CVV2":"123","secure3D":"cryptogramvalue123","MerchantID":"merchant_id","Login":"login","Password":"password"}
    '
  end

  def post_scrubbed
    '
      {"AuthOnly":false,"Amount":"1.00","CardNumber":"[FILTERED]","ExpDate":"0928","CVV2":"[FILTERED]","secure3D":"[FILTERED]","MerchantID":"merchant_id","Login":"login","Password":"[FILTERED]"}
    '
  end

  def successful_purchase_response
    '{"Status":"success","Message":"Approved","ConfirmationID":"CONF123"}'
  end

  def failed_purchase_response
    '{"Status":"failure","Message":"Declined","ConfirmationID":null}'
  end

  def successful_authorize_response
    '{"Status":"success","Message":"Approved","ConfirmationID":"CONF124"}'
  end

  def failed_authorize_response
    '{"Status":"failure","Message":"Declined","ConfirmationID":null}'
  end

  def successful_capture_response
    '{"Status":"success","Message":"Captured","ConfirmationID":"CONF124"}'
  end

  def failed_capture_response
    '{"Status":"failure","Message":"Capture failed","ConfirmationID":null}'
  end

  def successful_void_response
    '{"Status":"success","Message":"Voided","ConfirmationID":"CONF124"}'
  end

  def failed_void_response
    '{"Status":"failure","Message":"Void failed","ConfirmationID":null}'
  end
end
