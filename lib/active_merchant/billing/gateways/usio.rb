module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    # Field names below (CardNumber/ExpDate/AuthOnly/ConfirmationID/secure3D/Status/Message)
    # come from the USIO Payments API 2.0 docs (payments.usiopay.com/2.0/documentation) and
    # from the PBP-1330/CONN-2821 scoping thread, not from a verified sandbox exchange yet.
    # Confirm exact field names/casing against a live SubmitTokenPayment/PinlessMark/
    # SubmitCCVoid call before relying on this in production.
    class UsioGateway < Gateway
      self.test_url = 'https://devpayments.usiopay.com/2.0/payments.svc/JSON/'
      self.live_url = 'https://payments.usiopay.com/2.0/payments.svc/JSON/'

      self.supported_countries = %w[US CA]
      self.default_currency = 'USD'
      self.supported_cardtypes = %i[visa master american_express discover]

      self.homepage_url = 'https://usiopay.com/'
      self.display_name = 'USIO'

      def initialize(options = {})
        requires!(options, :merchant_id, :login, :password)
        super
      end

      def purchase(money, payment, options = {})
        post = {}
        add_auth_only(post, false)
        add_invoice(post, money, options)
        add_payment(post, payment)
        add_customer_data(post, options)
        commit('SubmitTokenPayment', post)
      end

      def authorize(money, payment, options = {})
        post = {}
        add_auth_only(post, true)
        add_invoice(post, money, options)
        add_payment(post, payment)
        add_customer_data(post, options)
        commit('SubmitTokenPayment', post)
      end

      def capture(money, authorization, options = {})
        post = {}
        add_invoice(post, money, options)
        add_reference(post, authorization)
        commit('PinlessMark', post)
      end

      # USIO has no separate void endpoint for AuthOnly transactions -
      # SubmitCCVoid auto-selects void vs. refund server-side based on the
      # referenced transaction's settlement status, so both refund and void
      # commit to the same action.
      def refund(money, authorization, options = {})
        post = {}
        add_invoice(post, money, options)
        add_reference(post, authorization)
        commit('SubmitCCVoid', post)
      end

      def void(authorization, options = {})
        post = {}
        add_reference(post, authorization)
        commit('SubmitCCVoid', post)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((&?"Password\\?":\\?")[^"\\]*)i, '\1[FILTERED]').
          gsub(%r((&?"CardNumber\\?":\\?")[^"\\]*)i, '\1[FILTERED]').
          gsub(%r((&?"CVV2?\\?":\\?")[^"\\]*)i, '\1[FILTERED]').
          gsub(%r((&?"secure3D\\?":\\?")[^"\\]*)i, '\1[FILTERED]')
      end

      private

      def add_auth_only(post, auth_only)
        post[:AuthOnly] = auth_only
      end

      def add_invoice(post, money, options)
        post[:Amount] = amount(money)
        post[:OrderID] = options[:order_id] if options[:order_id]
      end

      def add_customer_data(post, options)
        return unless (address = options[:billing_address] || options[:address])

        post[:Address] = address[:address1]
        post[:City] = address[:city]
        post[:State] = address[:state]
        post[:Zip] = address[:zip]
      end

      # ProcessTransactionWithToken always detokenizes back to a full PAN
      # before this gateway is invoked, so the CreditCard branch below is the
      # one exercised in practice today. The String branch is kept for parity
      # in case USIO's own permanent-token flow (SubmitCCVoid's ConfirmationID,
      # not a TokenEx token) is wired up as a payment source later.
      def add_payment(post, payment)
        if payment.is_a?(String)
          post[:ConfirmationID] = payment
        elsif payment.is_a?(NetworkTokenizationCreditCard)
          post[:CardNumber] = payment.number
          post[:ExpDate] = expdate(payment)
          # Per USIO guidance in PBP-1330 (unconfirmed against a live scheme
          # network token as of that thread): scheme cryptogram goes in
          # secure3D, which is otherwise the 3DS CAVV field. Not used for
          # actual 3DS on this adapter - 3DS is out of scope per TF Holdings.
          post[:secure3D] = payment.payment_cryptogram
        else
          post[:CardNumber] = payment.number
          post[:ExpDate] = expdate(payment)
          post[:CVV2] = payment.verification_value
          post[:FirstName] = payment.first_name
          post[:LastName] = payment.last_name
        end
      end

      def add_reference(post, authorization)
        post[:ConfirmationID] = authorization
      end

      def expdate(payment)
        "#{format(payment.month, :two_digits)}#{format(payment.year, :two_digits)}"
      end

      def parse(body)
        JSON.parse(body)
      end

      def commit(action, parameters)
        parameters[:MerchantID] = @options[:merchant_id]
        parameters[:Login] = @options[:login]
        parameters[:Password] = @options[:password]

        response = parse(ssl_post(url(action), post_data(parameters), headers))

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          test: test?
        )
      end

      def url(action)
        "#{test? ? test_url : live_url}#{action}"
      end

      def headers
        { 'Content-Type' => 'application/json' }
      end

      def post_data(parameters = {})
        parameters.to_json
      end

      def success_from(response)
        response['Status'].to_s.casecmp('success').zero?
      end

      def message_from(response)
        response['Message']
      end

      def authorization_from(response)
        response['ConfirmationID']
      end
    end
  end
end
