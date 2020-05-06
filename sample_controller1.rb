module V1
  module Orders
    class MerchandiseController < ApiController
      before_action :verify_authenticated_user

      def index
        order_history = ::Orders::History.new(user: current_user, params: {})
        order_history.merch_orders
        @orders = order_history.orders
      end

      def show
        @order = Order.joins(line_items: :merchandise).where(buyer_id: current_user[:id], id: params[:id]).first
        if @order.present?
          render
        else
          render json: {
            status: 'Not Found',
            message: I18n.t('errors.controllers.products.merch.order.not_found'),
            errors: [I18n.t('errors.controllers.products.merch.order.not_found')]
          }, status: 404
        end
      end

      def create
        retrieve_product
        @order_builder = ::Orders::Builders::Internal.new(buyer: current_user, seller: @product.owner, product: @product, currency_type: @product.currency_type)
        @order = @order_builder.build do |order|
          @product&.lock!
          raise ::Orders::Errors::NoProductError, I18n.t('errors.services.orders.product_out_of_stock') unless quantity_available?
          order.line_items[0].data = {variation: params[:size], buyer_info: params[:address] }

          variations = @product[:variation].map { |e| JSON.parse(e) }
          purchased_variation = variations.each do |variation|
            if variation[0] == params[:size]
              variation[-1] = (variation[-1].to_i - 1).to_s
            end
          end

          updated_variations = purchased_variation.map(&:to_json)

          MerchRedemptionMailer.send_notify_message({
            product_info: {
              name: @product.name,
              size: params[:size]
            },
            user_contact_info: {
              name: current_user[:first_name],
              email: current_user[:email],
              phone_number: current_user[:phone_number]
            },
            shipping_info: {
              name: params[:address][:name],
              address: params[:address][:street_address],
              address_2: params[:address][:address_line],
              city: params[:address][:city],
              state: params[:address][:state],
              zip: params[:address][:zipcode]
            }
          }).deliver_later
          MerchOrderConfirmationMailer.send_confirmation_mail(current_user[:email], @product.name).deliver_later

          @product.update(variation: updated_variations)
          @product.save!
        end
        render
      rescue StandardError => e
        render json: {
          status: 'fail',
          message: I18n.t('errors.controllers.products.merch.order.failed'),
          errors: [e.message]
        }, status: 422
      end

      private

      def retrieve_product
        @product = Merchandise.find_by(id: params[:id], type: Merchandise.to_s)
      end

      def quantity_available?
        variations = @product[:variation].map { |variation| JSON.parse(variation) }
        variations.select { |variation, quantity| variation == params[:size] && quantity.to_i.positive? }.any?
      end

    end
  end
end