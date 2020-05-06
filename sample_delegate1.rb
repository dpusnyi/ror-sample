require 'json'
require 'uphold'

class UpholdDelegate

  attr_accessor :client_id, :client_secret, :access_token

  UPHOLD_AUTHENTICATION_PATH = 'oauth2/token'.freeze
  UPHOLD_PROFILE_PATH = 'v0/me'.freeze
  UPHOLD_USER_CARDS_LIST_PATH = 'v0/me/cards'.freeze

  ##
  # Initializes a new UpholdDelegate
  #
  # @param [String] client_id used to identify the client app
  # @param [String] client_secret used to authenticate the requests to the external service
  #
  # @return [self]
  def initialize(client_id:, client_secret:, access_token: nil, transport: Faraday)
    @client_id = client_id.to_s
    @client_secret = client_secret.to_s
    @access_token = access_token.to_s
    @transport = transport
  end

  ##
  # Exchange code for access token
  #
  # @return [String]
  #   * @access_token [String] Used to access data on the users behalf
  def oauth_data(code:)
    res = uphold_conn.post do |req|
      req.url UPHOLD_AUTHENTICATION_PATH
      req.headers['Authorization'] = ActionController::HttpAuthentication::Basic.encode_credentials(client_id, client_secret)
      req.respond_to? :json, content_type: /\b(?i:json)$/
      req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
      req.body = URI.encode_www_form({code: code, grant_type: 'authorization_code'})
    end
    JSON.parse(res.body, symbolize_names: true).tap do |body|
      @access_token = body[:access_token]
    end
  end

  ##
  # Retrieve the user profile
  #
  # @return [Hash]
  # * :address [Hash]
  # * :birthdate [String]
  # * :country [String]
  # * :email [String]
  # * :firstName [String]
  # * :id [String]
  # * :identityCountry [String]
  # * :lastName [String]
  # * :name [String]
  # * :settings [String]
  # * :currency [String]
  # * :status [String]
  # * :username [String]
  # * :balances [Hash]
  def profile_data(access_token)
    response = uphold_conn.get do |req|
      req.url UPHOLD_PROFILE_PATH
      req.respond_to? :json, content_type: /\b(?i:json)$/
      req.headers[:Authorization] = "Bearer #{access_token}"
    end
    JSON.parse(response.body, symbolize_names: true)
  end

  def opt_method_id
    response = uphold_conn.get do |req|
      req.url UPHOLD_AUTH_METHODS_URL
      req.respond_to? :json, content_type: /\b(?i:json)$/
      req.headers[:Authorization] = "Bearer #{access_token}"
    end
    JSON.parse(response.body, symbolize_names: true)
  end

  def transaction(transaction_id:)
    client.find_public_transaction(id: transaction_id)
  end

  def create_and_commit_transaction(wallet_id:, currency:, amount:, destination:)
    client.create_and_commit_transaction(card_id: wallet_id, currency: currency, amount: amount, destination: destination)
  end

  def create_transaction(wallet_id:, currency:, amount:, destination:)
    uphold_conn.post do |req|
      req.url "#{UPHOLD_USER_CARDS_LIST_PATH}/#{wallet_id}/transactions"
      req.respond_to? :json, content_type: /\b(?i:json)$/
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{access_token}"
      req.body = {denomination: {amount: amount, currency: currency}, destination: destination}.to_json
    end
  end

  def commit_transaction(wallet_id, transaction_id, otp_code = nil)
    uphold_conn.post do |req|
      req.url "#{UPHOLD_USER_CARDS_LIST_PATH}/#{wallet_id}/transactions/#{transaction_id}/commit"
      req.respond_to? :json, content_type: /\b(?i:json)$/
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{access_token}"
      req.headers['otp-token'] = otp_code
    end
  end

  def cancel_transaction(wallet_id:, transaction_id:)
    client.cancel_transaction(card_id: wallet_id, transaction_id: transaction_id)
  end

  def resend_transaction(wallet_id:, transaction_id:)
    client.resend_transaction(card_id: wallet_id, transaction_id: transaction_id)
  end

  def card_details(card_id:)
    client.find_card(id: card_id)
  end

  def user_details
    client.me
  end

  def user_transactions
    client.all_user_transactions
  end

  def card_transactions
    client.all_card_transactions
  end

  def user_cards
    response = uphold_conn.get do |req|
      req.url UPHOLD_USER_CARDS_LIST_PATH
      req.respond_to? :json, content_type: /\b(?i:json)$/
      req.headers['Authorization'] = "Bearer #{access_token}"
      req.headers['Range'] = 'items=0-100'
    end

    JSON.parse(response.body, symbolize_names: true)
  end

  def balances(access_token:)
    @access_token = access_token
    profile = profile_data(@access_token)
    {
      balance: user_cards.select { |r| r[:currency] == "BAT" },
      memberAt: profile[:memberAt],
      settings: profile[:settings][:otp][:transactions]
    }
  end

  private

  def uphold_conn
    sandbox = StringUtility.to_boolean(ENV['UPHOLD_SANDBOX'])
    @transport.new sandbox ? ENV['UPHOLD_SANDBOX_BASE_URL'] : ENV['UPHOLD_BASE_URL'] do |c|
      c.adapter Faraday.default_adapter
      c.use Faraday::Response::RaiseError
    end
  end

  def client(access_token = @access_token)
    Uphold.sandbox = StringUtility.to_boolean(ENV['UPHOLD_SANDBOX'])
    @client ||= Uphold::Client.new(token: access_token)
  end

end