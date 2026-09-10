module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    class MerchantESolutionsGateway < Gateway
      include Empty

      self.test_url = 'https://cert.merchante-solutions.com/mes-api/tridentApi'
      self.live_url = 'https://api.merchante-solutions.com/mes-api/tridentApi'

      # The countries the gateway supports merchants from as 2 digit ISO country codes
      self.supported_countries = ['US']

      # The card types supported by the payment gateway
      self.supported_cardtypes = %i[visa master american_express discover jcb]

      # The homepage URL of the gateway
      self.homepage_url = 'http://www.merchante-solutions.com/'

      # The name of the gateway
      self.display_name = 'Merchant e-Solutions'

      SUCCESS_RESPONSE_CODES = %w(000 085)

      # Commercial / Purchase Card fields ("Level II").
      # Source: MeS Trident API spec, 'Commercial and Purchase Cards Table'.
      # Optional per the spec -- sending them obtains preferred interchange rates.
      # invoice_number is handled separately by add_invoice (from options[:order_id]).
      LEVEL_2_FIELDS = %i[
        tax_amount ship_to_zip
      ].freeze

      # Response Control fields. These are NOT Level II/III data -- they ask MeS to
      # return extra information in the response ("Response Control" section of the
      # API spec). rctl_commercial_card=y returns the commercial card type, and the
      # MeS certification script requires it on the Level 2/3 scenarios.
      # Other members of this family (rctl_product_level, rctl_Extended_AVS,
      # rctl_partial_auth, ...) are not wired up; add them here if needed.
      RESPONSE_CONTROL_FIELDS = %i[
        rctl_commercial_card
      ].freeze

      # Level III header fields.
      # Source: MeS Trident API spec, 'Visa and Mastercard Level 3 Fields Table' plus
      # the 'American Express Commercial and Purchase Cards' Level 3 table.
      # Brand applicability per the spec:
      #   Visa + Mastercard : line_item_count, duty_amount, ship_to_zip,
      #                       ship_from_zip, dest_country_code
      #   Visa only         : merchant_tax_id, customer_tax_id,
      #                       summary_commodity_code, discount_amount,
      #                       shipping_amount, vat_invoice_number, order_date,
      #                       vat_amount
      #   Mastercard only   : alt_tax_amount, alt_tax_amount_indicator
      #   Amex only         : requester_name, cardholder_reference_number
      # One flat list is safe -- MeS ignores params that do not apply to the brand.
      #
      # Spec caveats not enforced here (caller's responsibility):
      #   * line_item_count is capped at 950 for Visa/Mastercard but only 4 for Amex.
      #   * When alt_tax_amount_indicator is N the spec says send alt_tax_amount as
      #     0000000000.00. The certification script uses 0.00 instead -- see MOD-994.
      LEVEL_3_FIELDS = %i[
        line_item_count merchant_tax_id customer_tax_id summary_commodity_code
        discount_amount shipping_amount duty_amount ship_from_zip
        dest_country_code vat_invoice_number vat_amount order_date
        alt_tax_amount alt_tax_amount_indicator
        requester_name cardholder_reference_number
      ].freeze

      LINE_ITEM_DELIMITER = '<|>'.freeze

      # Level III line-item sub-field order, per card brand. MeS validates both the
      # field count and the order; a malformed item is rejected with
      # error_code=127 / auth_response_text='Invalid Level III Line Item Detail'.
      #
      # Source: MeS Trident API spec -- 'Visa Line Item Fields for Level 3',
      # 'Mastercard Line Item Fields for Level 3', and 'American Express Line Item
      # Fields'. Cross-checked against the certification script (cells H25/H27/H29);
      # the two agree.
      #
      #   VISA (11)       Item Commodity Code | Item Descriptor | Product Code |
      #                   Quantity | Unit of Measure | Unit Cost | VAT Tax Amount |
      #                   VAT Tax Rate | Discount per Line Item | Line Item Total |
      #                   Debit or Credit Indicator
      #   MASTERCARD (13) Item Description | Product Code | Item Quantity |
      #                   Item Unit of Measure | Alternate Tax Identifier |
      #                   Tax Rate Applied | Tax Type Applied | Tax Amount |
      #                   Discount Indicator | Net or Gross Indicator |
      #                   Extended Item Amount | Debit or Credit Indicator |
      #                   Discount Amount
      #   AMEX (3)        Item Description | Item Quantity | Item Unit Cost
      #                   (spec: "Item Unit Cost should not exceed transaction_amount")
      #
      # Wire encoding: the spec requires the body to be percent-encoded per RFC 3986,
      # so the literal '<|>' is transmitted as %3C%7C%3E. post_data's CGI.escape
      # already does this -- do not special-case the delimiter.
      LINE_ITEM_FIELDS = {
        visa_line_item: %i[
          commodity_code description product_code quantity unit_of_measure
          unit_cost vat_tax_amount vat_tax_rate discount_per_line_item
          line_item_total debit_or_credit_indicator
        ],
        mc_line_item: %i[
          description product_code quantity unit_of_measure
          alternate_tax_identifier tax_rate_applied tax_type_applied tax_amount
          discount_indicator net_or_gross_indicator extended_item_amount
          debit_or_credit_indicator discount_amount
        ],
        # Amex has only three sub-fields and the third is Unit Cost -- not
        # Line Item Total. Visa carries both; Amex does not.
        amex_line_item: %i[description quantity unit_cost]
      }.freeze

      def initialize(options = {})
        requires!(options, :login, :password)
        super
      end

      def authorize(money, creditcard_or_card_id, options = {})
        post = {}
        add_invoice(post, options)
        add_payment_source(post, creditcard_or_card_id, options)
        add_address(post, options)
        add_3dsecure_params(post, options)
        add_stored_credentials(post, options)
        add_level_2_fields(post, options)
        add_level_3_fields(post, options)
        add_response_control_fields(post, options)
        commit('P', money, post)
      end

      def purchase(money, creditcard_or_card_id, options = {})
        post = {}
        add_invoice(post, options)
        add_payment_source(post, creditcard_or_card_id, options)
        add_address(post, options)
        add_3dsecure_params(post, options)
        add_stored_credentials(post, options)
        add_level_2_fields(post, options)
        add_level_3_fields(post, options)
        add_response_control_fields(post, options)
        commit('D', money, post)
      end

      def capture(money, transaction_id, options = {})
        post = {}
        post[:transaction_id] = transaction_id
        post[:client_reference_number] = options[:customer] if options.has_key?(:customer)
        add_invoice(post, options)
        add_3dsecure_params(post, options)
        add_level_2_fields(post, options)
        add_level_3_fields(post, options)
        add_response_control_fields(post, options)
        commit('S', money, post)
      end

      def store(creditcard, options = {})
        MultiResponse.run do |r|
          r.process { temporary_store(creditcard, options) }
          r.process { verify(r.authorization, { store_card: 'y' }) }
        end
      end

      def unstore(card_id, options = {})
        post = {}
        post[:client_reference_number] = options[:customer] if options.has_key?(:customer)
        post[:card_id] = card_id
        commit('X', nil, post)
      end

      def refund(money, identification, options = {})
        post = {}
        post[:transaction_id] = identification
        post[:client_reference_number] = options[:customer] if options.has_key?(:customer)
        options.delete(:customer)
        options.delete(:billing_address)
        commit('U', money, options.merge(post))
      end

      def credit(money, creditcard_or_card_id, options = {})
        post = {}
        post[:client_reference_number] = options[:customer] if options.has_key?(:customer)
        add_invoice(post, options)
        add_payment_source(post, creditcard_or_card_id, options)
        commit('C', money, post)
      end

      def void(transaction_id, options = {})
        post = {}
        post[:transaction_id] = transaction_id
        post[:client_reference_number] = options[:customer] if options.has_key?(:customer)
        options.delete(:customer)
        options.delete(:billing_address)
        commit('V', nil, options.merge(post))
      end

      def verify(credit_card, options = {})
        post = {}
        post[:store_card] = options[:store_card] if options[:store_card]
        add_payment_source(post, credit_card, options)
        commit('A', 0, post)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((&?profile_key=)\w*(&?)), '\1[FILTERED]\2').
          gsub(%r((&?card_number=)\d*(&?)), '\1[FILTERED]\2').
          gsub(%r((&?cvv2=)\d*(&?)), '\1[FILTERED]\2')
      end

      private

      def temporary_store(creditcard, options = {})
        post = {}
        post[:client_reference_number] = options[:customer] if options.has_key?(:customer)
        add_creditcard(post, creditcard, options)
        commit('T', nil, post)
      end

      def add_address(post, options)
        if address = options[:billing_address] || options[:address]
          post[:cardholder_street_address] = address[:address1].to_s.gsub(/[^\w.]/, '+')
          post[:cardholder_zip] = address[:zip].to_s
        end
      end

      def add_invoice(post, options)
        if options.has_key? :order_id
          order_id = options[:order_id].to_s.gsub(/[^\w.]/, '')
          post[:invoice_number] = truncate(order_id, 17)
        end
      end

      def add_payment_source(post, creditcard_or_card_id, options)
        if creditcard_or_card_id.is_a?(String)
          # using stored card
          post[:card_id] = creditcard_or_card_id
          post[:card_exp_date] = options[:expiration_date] if options[:expiration_date]
        else
          # card info is provided
          add_creditcard(post, creditcard_or_card_id, options)
        end
      end

      def add_creditcard(post, creditcard, options)
        post[:card_number] = creditcard.number
        post[:cvv2] = creditcard.verification_value if creditcard.verification_value?
        post[:card_exp_date] = expdate(creditcard)
      end

      def add_3dsecure_params(post, options)
        post[:xid] = options[:xid] unless empty?(options[:xid])
        post[:cavv] = options[:cavv] unless empty?(options[:cavv])
        post[:ucaf_collection_ind] = options[:ucaf_collection_ind] unless empty?(options[:ucaf_collection_ind])
        post[:ucaf_auth_data] = options[:ucaf_auth_data] unless empty?(options[:ucaf_auth_data])
      end

      def add_stored_credentials(post, options)
        # options[:customer] is the ActiveMerchant convention for the gateway's
        # customer reference field; capture/credit/refund/void/unstore/store already
        # map it onto client_reference_number, but authorize/purchase did not, so a
        # :customer on a sale was silently dropped. An explicit
        # :client_reference_number takes precedence over the alias.
        #
        # Spec note: client_reference_number is AN(96) and the spec says "Do not
        # send & or =". No sanitising happens here, matching the six pre-existing
        # call sites -- CGI.escape keeps the wire valid, but MeS decodes those
        # characters back out, so callers should avoid them.
        client_reference_number = options[:client_reference_number] || options[:customer]
        post[:client_reference_number] = client_reference_number if client_reference_number
        post[:moto_ecommerce_ind] = options[:moto_ecommerce_ind] if options[:moto_ecommerce_ind]
        post[:recurring_pmt_num] = options[:recurring_pmt_num] if options[:recurring_pmt_num]
        post[:recurring_pmt_count] = options[:recurring_pmt_count] if options[:recurring_pmt_count]
        post[:card_on_file] = options[:card_on_file] if options[:card_on_file]
        post[:cit_mit_indicator] = options[:cit_mit_indicator] if options[:cit_mit_indicator]
        post[:account_data_source] = options[:account_data_source] if options[:account_data_source]
        # Merchant-initiated transaction flag, AN(1), 'Y' or 'N' (default). The spec
        # pairs merchant_initiated=Y with card_on_file=Y, account_data_source=Y and
        # an M1xx cit_mit_indicator. Not exercised by the MeS certification script
        # (which only uses C101, cardholder-initiated) but required for correct MIT
        # identification and interchange qualification.
        post[:merchant_initiated] = options[:merchant_initiated] if options[:merchant_initiated]
        # Subsequent CIT/MIT requires the transaction_id of the prior approved
        # authorization for these credentials. capture/refund/void take it as a
        # positional argument; on authorize/purchase it can only arrive via options.
        post[:transaction_id] = options[:transaction_id] if options[:transaction_id]
      end

      def add_level_2_fields(post, options)
        copy_present_params(post, options, LEVEL_2_FIELDS)
      end

      def add_response_control_fields(post, options)
        copy_present_params(post, options, RESPONSE_CONTROL_FIELDS)
      end

      def add_level_3_fields(post, options)
        copy_present_params(post, options, LEVEL_3_FIELDS)

        LINE_ITEM_FIELDS.each_key do |key|
          next if empty?(options[key])

          post[key] = build_line_item(key, options[key])
        end
      end

      # A line item may be supplied either already MeS-formatted (a String, passed
      # through untouched -- use this to send multiple items) or as a Hash, which is
      # assembled into the brand-specific '<|>'-delimited composite. Hash keys may
      # be symbols or strings and follow LINE_ITEM_FIELDS ordering.
      def build_line_item(key, value)
        return value if value.is_a?(String)

        LINE_ITEM_FIELDS[key].map { |field| value[field] || value[field.to_s] }.
          join(LINE_ITEM_DELIMITER)
      end

      # Not Empty#empty?: that reports numeric 0 as absent
      # (see lib/active_merchant/empty.rb -- `when Numeric then (value == 0)`),
      # which would silently drop a legitimate zero amount.
      #
      # Zero-valued Level 3 amounts are real values rather than omissions. The MeS
      # certification script sends shipping_amount=0.00, duty_amount=0.00,
      # vat_amount=0.00 and alt_tax_amount=0.00 (source: certification test script,
      # sheets 'Level 2_3 COF - CIT' / 'Level 2_3 NO COF', example query strings in
      # rows 25/27/29). This has NOT been cross-checked against the MeS API spec --
      # it is what the certification script requires.
      #
      # Scope note: the TokenEx wrapper stringifies numerics before calling this
      # adapter, so requests arriving through PaymentServices send "0.00" as a String
      # and would survive empty? anyway. This guard matters for direct Ruby callers of
      # the gem, which can pass a numeric 0.
      def copy_present_params(post, options, fields)
        fields.each do |field|
          value = options[field]
          next if value.nil?
          next if value.is_a?(String) && value.strip.empty?

          post[field] = value
        end
      end

      def parse(body)
        results = {}
        body.split(/&/).each do |pair|
          key, val = pair.split(/=/)
          results[key] = val
        end
        results
      end

      def commit(action, money, parameters)
        url = test? ? self.test_url : self.live_url
        parameters[:transaction_amount] = amount(money) if !(action == 'V') && money

        response =
          begin
            parse(ssl_post(url, post_data(action, parameters)))
          rescue ActiveMerchant::ResponseError => e
            { 'error_code' => '404', 'auth_response_text' => e.to_s }
          end

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          test: test?,
          cvv_result: response['cvv2_result'],
          avs_result: { code: response['avs_result'] }
        )
      end

      def authorization_from(response)
        return response['card_id'] if response['card_id']

        response['transaction_id']
      end

      def success_from(response)
        SUCCESS_RESPONSE_CODES.include?(response['error_code'])
      end

      def message_from(response)
        if response['error_code'] == '000'
          'This transaction has been approved'
        else
          response['auth_response_text']
        end
      end

      def post_data(action, parameters = {})
        post = {}
        post[:profile_id] = @options[:login]
        post[:profile_key] = @options[:password]
        post[:transaction_type] = action if action

        post.merge(parameters).map { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }.join('&')
      end
    end
  end
end
