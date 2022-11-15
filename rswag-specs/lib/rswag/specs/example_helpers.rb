# frozen_string_literal: true

require 'rswag/specs/request_factory'
require 'rswag/specs/oas3/request_factory'
require 'rswag/specs/response_validator'

module Rswag
  module Specs
    module ExampleHelpers
      def submit_request(metadata)
        swagger_doc = ::Rswag::Specs.config.get_swagger_doc(metadata[:swagger_doc])
        version = swagger_doc[:openapi] || swagger_doc[:swagger] || '2'

        request = if version.start_with?('2')
                    RequestFactory.new.build_request(metadata, self)
                  else
                    Oas3::RequestFactory.new.build_request(metadata, self)
                  end

        if RAILS_VERSION < 5
          send(
            request[:verb],
            request[:path],
            request[:payload],
            request[:headers]
          )
        else
          send(
            request[:verb],
            request[:path],
            params: request[:payload],
            headers: request[:headers]
          )
        end
      end

      def assert_response_matches_metadata(metadata)
        ResponseValidator.new.validate!(metadata, response)
      end
    end
  end
end
