# frozen_string_literal: true

module Cloudtasker
  module UniqueJob
    module Middleware
      # TODO: kwargs to job otherwise it won't get the time_at
      # Client middleware, invoked when jobs are scheduled
      class Client
        def call(worker, _opts = {}, &block)
          Job.new(worker).lock_instance.schedule(&block)
        end
      end
    end
  end
end
