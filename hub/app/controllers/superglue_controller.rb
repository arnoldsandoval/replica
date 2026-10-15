# Provides React rendering defaults to browser application pages.
class SuperglueController < ApplicationController
  before_action :use_jsx_rendering_defaults
end
