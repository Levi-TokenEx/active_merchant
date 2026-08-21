module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    # Field names below (RoutingNumber/AccountNumber/AccountType/TransactionType/
    # ConfirmationID/Status/Message) come from the USIO Payments API 2.0 docs
    # (payments.usiopay.com/2.0/documentation) and the PBP-1330 scoping thread.
    # The void/return endpoint name is assumed by symmetry with SubmitACHPayment -
    # confirm the real endpoint name and field casing against USIO's ACH API
    # collection/sandbox before relying on this in production. Only the debit
    # (pull-funds) direction is implemented: standalone ACH credit (push funds
    # out) isn't reachable through ProcessTransactionWithToken (the wrapper never
    # dispatches a `credit` action), and async batch/return polling is a
    # separate reconciliation job, not part of this gateway.
    class UsioAchGateway < Gateway
      self.test_url = 'https://devpayments.usiopay.com/2.0/payments.svc/JSON/'
      self.live_url = 'https://payments.usiopay.com/2.0/payments.svc/JSON/'

      self.supported_countries = %w[US CA]
      self.default_currency = 'USD'
      self.supported_cardtypes = []

      self.homepage_url = 'https://usiopay.com/'
      self.display_name = 'USIO ACH'

      def initialize(options = {})
        requires!(options, :merchant_id, :login, :password)
        super
      end

      def purchase(money, payment, options = {})
        post = {}
        post[:TransactionType] = 'Debit'
        add_invoice(post, money, options)
        add_payment(post, payment)
        add_customer_data(post, options)
        commit('SubmitACHPayment', post)
      end

      def refund(money, authorization, options = {})
        post = {}
        add_invoice(post, money, options)
        add_reference(post, authorization)
        commit('SubmitACHVoid', post)
      end

      def void(authorization, options = {})
        post = {}
        add_reference(post, authorization)
        commit('SubmitACHVoid', post)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((&?"Password\\?":\\?")[^"\\]*)i, '\1[FILTERED]').
          gsub(%r((&?"AccountNumber\\?":\\?")[^"\\]*)i, '\1[FILTERED]').
          gsub(%r((&?"RoutingNumber\\?":\\?")[^"\\]*)i, '\1[FILTERED]')
      end

      private

      def add_invoice(post, money, options)
        post[:Amount] = amount(money)
        post[:OrderID] = options[:order_id] if options[:order_id]
      end

      def add_payment(post, payment)
        if payment.is_a?(String)
          post[:ConfirmationID] = payment
        else
          post[:RoutingNumber] = payment.routing_number
          post[:AccountNumber] = payment.account_number
          post[:AccountType] = payment.account_type
          post[:Name] = payment.name
        end
      end

      def add_customer_data(post, options)
        return unless (address = options[:billing_address] || options[:address])

        post[:Address] = address[:address1]
        post[:City] = address[:city]
        post[:State] = address[:state]
        post[:Zip] = address[:zip]
      end

      def add_reference(post, authorization)
        post[:ConfirmationID] = authorization
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
