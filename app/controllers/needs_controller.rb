class NeedsController < ApplicationController
  def new; end

  def create
    file = params[:file]
    return redirect_to(root_path, alert: "Choisis un fichier CSV.") if file.blank?

    calculator = NeedsCalculator.new(file.read)
    @result = calculator.call
    @warnings = calculator.warnings
    render :show
  rescue NeedsCalculator::Error => e
    redirect_to root_path, alert: e.message
  end
end