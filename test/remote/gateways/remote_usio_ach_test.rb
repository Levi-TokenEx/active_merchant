require 'test_helper'

class RemoteUsioAchTest < Test::Unit::TestCase
  def setup
    @gateway = UsioAchGateway.new(fixtures(:usio_ach))

    @amount = 100
    @check = check
    @options = {
      order_id: generate_unique_id,
      billing_address: address
    }
  end

  def test_successful_purchase
    response = @gateway.purchase(@amount, @check, @options)
    assert_success response
  end

  def test_failed_purchase
    response = @gateway.purchase(@amount, check(account_number: ''), @options)
    assert_failure response
  end

  def test_successful_refund
    purchase = @gateway.purchase(@amount, @check, @options)
    assert_success purchase

    refund = @gateway.refund(@amount, purchase.authorization)
    assert_success refund
  end

  def test_failed_refund
    response = @gateway.refund(@amount, '')
    assert_failure response
  end

  def test_successful_void
    purchase = @gateway.purchase(@amount, @check, @options)
    assert_success purchase

    void = @gateway.void(purchase.authorization)
    assert_success void
  end

  def test_failed_void
    response = @gateway.void('')
    assert_failure response
  end

  def test_transcript_scrubbing
    transcript = capture_transcript(@gateway) do
      @gateway.purchase(@amount, @check, @options)
    end
    transcript = @gateway.scrub(transcript)

    assert_scrubbed(@check.account_number, transcript)
    assert_scrubbed(@check.routing_number, transcript)
    assert_scrubbed(@gateway.options[:password], transcript)
  end
end
