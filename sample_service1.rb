require 'json'

class UpholdAccountService
  attr_accessor :user, :new_user, :event_invites, :tap_partner

  class UpholdUserNotFoundException < StandardError
  end

  class UpholdAccessFailedException < StandardError
  end

  def login(code:, device_params:, tap_partner:, transport: Faraday)
    @tap_partner = tap_partner
    @transport = transport
    @uphold_profile = retrieve_profile(code)
    if !@uphold_profile || @uphold_profile[:id].empty?
      raise UpholdAccessFailedException, I18n.t('errors.services.uphold.access_failed')
    end

    @user = find_user_by_account_provider
    if @user
      # update user data
      update_user
    else
      unless @uphold_profile[:email].nil?
        @user = account_service.find_user_by_email(@uphold_profile[:email], tap_partner)
      end
      if @user.nil?
        # Create user
        account_service.create_user(build_user_params, device_params, tap_partner, true)
        @user = account_service.user
        @new_user = true
      elsif @user.uphold_data
        # update uphold data to the appropriate id
        update_user
      else
        # create provider data
        update_provider_data(@access_token)
      end
    end
    account_service.login_user(@user, nil, device_params)
    @event_invites = account_service.event_invites
  end

  def get_balance(user, tap_partner)
    @tap_partner = tap_partner
    token = get_uphold_token(user.id)
    delegate.balances(access_token: token.access_token)
  end

  private

  def retrieve_profile(code)
    get_access_token(code)
    delegate.profile_data(@access_token)
  end

  def find_user_by_account_provider
    account_provider_data = AccountProviderData.joins(:user).find_by(
      account_provider_id: uphold_account_provider.id,
      account_provider_user_id: @uphold_profile[:id],
      users: {tap_merchant: tap_partner}
    )
    account_provider_data.try(:user)
  end

  def build_user_params
    name = clean_name(@uphold_profile[:name])
    birthday = @uphold_profile[:birthdate]
    {
      first_name: name[0],
      last_name: name[1],
      birthday: birthday,
      tap_merchant: @tap_partner,
      account_provider_data: [AccountProviderData.new(build_account_provider_params(@access_token))]
    }.merge(email)
  end

  def build_account_provider_params(access_token)
    {
      account_provider_user_id: @uphold_profile[:id],
      access_token: access_token,
      account_provider_id: uphold_account_provider.id
    }
  end

  def update_user
    add_info_to_user(@uphold_profile)
    update_provider_data(@access_token)
  end

  def add_info_to_user(profile)
    name = clean_name(profile.fetch(:name))
    @user.email ||= email
    @user.first_name ||= name[0]
    @user.last_name ||= name[1]
    @user.birthday ||= adjust_birthday(profile.fetch(:birthdate))
    @user.tap_merchant ||= tap_partner
    @user.update(completed_onboarding: true)
    @user.save
  end

  def clean_name(name)
    if name.nil?
      ['', '']
    else
      name.split(' ', 2)
    end
  end

  def update_provider_data(access_token)
    data_hash = {
      account_provider_user_id: @uphold_profile[:id],
      access_token: access_token,
      picture_url: @uphold_profile[:picture]
    }
    if @user.uphold_data
      @user.uphold_data.update(data_hash)
    else
      @user.account_provider_data << AccountProviderData.new({account_provider: uphold_account_provider}.merge(data_hash))
    end
  end

  def email
    if @uphold_profile[:email]
      {email: downcase_email(@uphold_profile[:email])}
    else
      {}
    end
  end

  def downcase_email(email)
    email.try(:downcase)
  end

  def get_uphold_token(user_id)
    @account_provider_data ||= AccountProviderData.find_by(user_id: user_id)
  end

  def adjust_birthday(birthday)
    DateUtility.date_time_from_mm_dd_yyyy(birthday)
  end

  def get_access_token(code)
    oauth = delegate.oauth_data(code: code)
    @access_token = oauth[:access_token]
  end

  def delegate
    @delegate ||= UpholdDelegate.new(
      client_id: account_provider_credentials.client_id,
      client_secret: account_provider_credentials.client_secret,
      access_token: @access_token
    )
  end

  def account_service
    @account_service ||= AccountService.new
  end

  def uphold_account_provider
    @uphold_account_provider ||= AccountProvider.find_by(name: AccountProvider::UPHOLD)
  end

  def account_provider_credentials
    @account_provider_credentials ||= @tap_partner.account_provider_credentials.uphold
  end
end