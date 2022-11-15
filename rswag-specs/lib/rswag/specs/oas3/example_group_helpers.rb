# frozen_string_literal: true

require 'active_support'

module Rswag
  module Specs
    module Oas3
      # OAS3 specific example group helpers
      module ExampleGroupHelpers
        # Supports https://swagger.io/docs/specification/describing-request-body/
        def request_body(media_type, attributes)
          if schema = attributes.delete(:schema)
            attributes[:content] = {
              media_type => {
                schema: schema
              }
            }
          end
          attributes[:required] = schema[:required]&.any?
          metadata[:operation][:requestBody] = attributes
        end

        def request_body_form(attributes)
          request_body("application/x-www-form-urlencoded", attributes)
        end

        def request_body_json(attributes)
          request_body("application/json", attributes)
        end

        def request_body_xml(attributes)
          request_body("application/xml", attributes)
        end

        def request_body_plain(attributes)
          request_body("text/plain", attributes)
        end
      end
    end
  end
end
