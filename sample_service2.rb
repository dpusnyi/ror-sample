class FacebookAccountService
  attr_accessor :user, :new_user, :event_invites, :tap_partner

  class FacebookUserNotFoundException < StandardError; end

  class FacebookAccessFailedException < StandardError; end

  def login_with_code(code, device_params, tap_partner)
    @tap_partner = tap_partner
    @delegate ||= initialize_delegate(code: code)
    access_token = @delegate.exchange_authentication_code
    login(access_token, device_params, tap_partner)
  end

  def login(facebook_params, device_params, tap_partner)
    @tap_partner ||= tap_partner
    @delegate ||= initialize_delegate(facebook_params)
    access_token = facebook_params[:code].present? ? @delegate.exchange_authentication_code : facebook_params[:fb_access_token]
    @facebook_profile = retrieve_profile

    if !@facebook_profile || @facebook_profile[:id].empty?
      raise FacebookAccessFailedException, I18n.t('errors.services.facebook.access_failed')
    end

    @user = find_user_by_account_provider(tap_partner)

    if @user
      # update user data
      update_user(access_token)
      # log user in
      account_service.login_user(@user, nil, device_params)
    else
      if !@facebook_profile[:email].nil?
        @user = account_service.find_user_by_email(@facebook_profile[:email], tap_partner)
      end

      if @user.nil?
        # Create user
        account_service.create_user(build_user_params(access_token), device_params, tap_partner, true)
        @user = account_service.user
        @new_user = true
      else
        if @user.facebook_data
          # update facebook data to the appropriate id
          update_user(access_token)
        else
          # create provider data
          update_provider_data(access_token)
        end
      end
      # log user in
      account_service.login_user(@user, nil, device_params)
    end

    @event_invites = account_service.event_invites
  end

  def update_user(access_token)
    add_info_to_user
    update_provider_data(access_token)
  end

  def build_user_params(access_token)
    name = clean_name(@facebook_profile[:name])
    birthday = @facebook_profile[:birthday]
    gender = @facebook_profile[:gender]
    {
        first_name: name[0],
        last_name: name[1],
        birthday: birthday,
        gender: gender,
        tap_merchant: tap_partner,
        account_provider_data: [AccountProviderData.new(build_account_provider_params(access_token))]
    }.merge(email)
  end

  def clean_name(name)
    if name.nil?
      ['', '']
    else
      name.split(' ', 2)
    end
  end

  def build_account_provider_params(access_token)
    {
        account_provider_user_id: @facebook_profile[:id],
        access_token: access_token,
        picture_url: @facebook_profile[:picture],
        account_provider_id: account_provider.id
    }
  end

  def add_info_to_user
    name = clean_name(@facebook_profile[:name])
    birthday = adjust_birthday(@facebook_profile[:birthday])
    gender = @facebook_profile[:gender]
    @user.email = email if @user.email.blank?
    @user.first_name = name[0] if @user.first_name.blank?
    @user.last_name = name[1] if @user.last_name.blank?
    @user.gender = gender if @user.gender.blank?
    @user.birthday = birthday if @user.birthday.blank?
  end

  def update_provider_data(access_token)
    data_hash = {
        account_provider_user_id: @facebook_profile[:id],
        access_token: access_token,
        picture_url: @facebook_profile[:picture]
    }
    if @user.facebook_data
      @user.facebook_data.update(data_hash)
    else
      @user.account_provider_data << AccountProviderData.new({account_provider: account_provider}.merge(data_hash))
    end
  end

  def retrieve_profile
    @delegate.fetch!.try(:symbolize_keys)
  end

  def find_user_by_account_provider(tap_partner)
    account_provider_data = AccountProviderData.joins(:user).find_by(
      account_provider_id: account_provider.id,
      account_provider_user_id: @facebook_profile[:id],
      users: { tap_merchant: tap_partner }
    )

    account_provider_data.try(:user)
  end

  private

  def initialize_delegate(facebook_params)
    FacebookDelegate.new(
      access_token: facebook_params[:fb_access_token],
      code: facebook_params[:code],
      redirect_uri: facebook_params[:redirect_uri],
      version: facebook_params[:version],
      client_id: account_provider_credentials.client_id,
      client_secret: account_provider_credentials.client_secret
    )
  end

  def adjust_birthday(birthday)
    DateUtility.date_time_from_mm_dd_yyyy(birthday)
  end

  def downcase_email(email)
    email.try(:downcase)
  end

  def account_service
    @account_service ||= AccountService.new
  end

  def account_provider
    @account_provider ||= AccountProvider.find_by(name: AccountProvider::FACEBOOK)
  end

  def account_provider_credentials
    @account_provider_credentials ||= @tap_partner.account_provider_credentials.facebook
  end

  def email
    if @facebook_profile[:email]
      {email: downcase_email(@facebook_profile[:email])}
    else
      {}
    end
  end
end
