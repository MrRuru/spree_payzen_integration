# Handles checkout logic.  This is somewhat contrary to standard REST convention since there is not actually a
# Checkout object.  There's enough distinct logic specific to checkout which has nothing to do with updating an
# order that this approach is waranted.
class CheckoutController < Spree::BaseController
  ssl_required

  # Already executed in checkout controller before_filter :load_order 
  protect_from_forgery :except => [:payzen]

  # The current order doesn't exist anymore, we don't want to load it
  before_filter :load_order, :except => [:payzen, :payzen_back]
  
  # The admin privileges are asked for payzen_back
  # This fixes the issue (the user still needs to be logged in)
  before_filter :check_authorization, :except => :payzen_back

  rescue_from Spree::GatewayError, :with => :rescue_from_spree_gateway_error

  respond_to :html

  # Updates the order and advances to the next state (when possible.)
  def update
    if @order.payzen_validation and @order.update_attributes(object_params)
      # should prevent update from => 'confirm',  to => 'complete' when payment is made with Payzen.
      # Actually, this has to be done through Payzen callback
      if @order.next
        state_callback(:after)
      else
        flash[:error] = I18n.t(:payment_processing_failed)
        respond_with(@order, :location => checkout_state_path(@order.state))
        return
      end

      if @order.state == "complete" || @order.completed?
        flash[:notice] = I18n.t(:order_processed_successfully)
        flash[:commerce_tracking] = "nothing special"
        respond_with(@order, :location => completion_route)
      else
        respond_with(@order, :location => checkout_state_path(@order.state))
      end
    else
      respond_with(@order) { |format| format.html { render :edit } }
    end
  end
  
  
  # Payzen asynchronous callback
  def payzen
    # Get the order, payment and payzen parameters
    # if Rails.env == 'production'
      @order = Order.where(:number => params["vads_order_id"]).first #find_by_number(params["vads_order_id"]) # pas l'ID, le number (mais unique aussi)
    # else
    #   @order = current_order
    # end
    
    @payment = @order.payments.last #TODO check this
    @payment.started_processing
    
    # Check if the payment is ok
    begin 
      PayzenIntegration::Params.check_returned_params(params) # if Rails.env == 'production'
    rescue Exception => e
      # log the exception ? Save it as a payment parameter ?
      @payment.fail
      render :text => "Payzen error : #{e.message} for order #{@order.id}" and return
    end
  
    @payment.complete

    # @order.next #:from => 'payment', :to => 'confirm' 
    # state_callback(:after)
    # state_callback(:before)
    
    @order.next #:from => 'confirm', :to => 'complete' 
    state_callback(:after)
    render :text => "done"
  end
    
  # Payzen return to website
  def payzen_back
    # Get the last order
    @order = current_user.orders.complete.last    
    redirect_to cart_path and return unless @order
     
    # Show the summary
    flash[:notice] = I18n.t(:order_processed_successfully)
    flash[:commerce_tracking] = "nothing special"    
    render "orders/show"
  end
  
  private

  # Provides a route to redirect after order completion
  def completion_route
    order_path(@order)
  end

  def object_params
    # For payment step, filter order parameters to produce the expected nested attributes for a single payment and its source, discarding attributes for payment methods other than the one selected
    if @order.payment?
      if params[:payment_source].present? && source_params = params.delete(:payment_source)[params[:order][:payments_attributes].first[:payment_method_id].underscore]
        params[:order][:payments_attributes].first[:source_attributes] = source_params
      end
      if (params[:order][:payments_attributes])
        params[:order][:payments_attributes].first[:amount] = @order.total
      end
    end
    params[:order]
  end

  def load_order
    @order = current_order
    redirect_to cart_path and return unless @order and @order.checkout_allowed?
    redirect_to cart_path and return if @order.completed?
    @order.state = params[:state] if params[:state]
    state_callback(:before)
  end

  def state_callback(before_or_after = :before)
    method_name = :"#{before_or_after}_#{@order.state}"
    send(method_name) if respond_to?(method_name, true)
  end

  def before_address
    @order.bill_address ||= Address.default
    @order.ship_address ||= Address.default
  end

  def before_delivery
    return if params[:order].present?
    @order.shipping_method ||= (@order.rate_hash.first && @order.rate_hash.first[:shipping_method])
  end

  def before_payment
    current_order.payments.destroy_all if request.put?
  end

  def after_complete
    session[:order_id] = nil
  end

  def rescue_from_spree_gateway_error
    flash[:error] = t('spree_gateway_error_flash_for_checkout')
    render :edit
  end

end