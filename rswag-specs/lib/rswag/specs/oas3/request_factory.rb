# frozen_string_literal: true

require "active_support"
require 'active_support/core_ext/hash/slice'
require 'active_support/core_ext/hash/conversions'
require 'json'

module Rswag
  module Specs
    module Oas3
      class RequestFactory < Rswag::Specs::RequestFactory
        MAX_DEPTH = 3

        def expand_parameters(metadata, swagger_doc, example)
          operation_params = metadata[:operation][:parameters] || []
          path_item_params = metadata[:path_item][:parameters] || []
          security_params = derive_security_params(metadata, swagger_doc)

          # NOTE: Use of + instead of concat to avoid mutation of the metadata object
          (operation_params + path_item_params + security_params)
            .map { |p| p['$ref'] ? resolve_parameter(p['$ref'], swagger_doc) : p }
            .uniq { |p| p[:name] }
            .reject { |p| p[:required] == false && !example.respond_to?(p[:name]) }
        end

        def derive_security_params(metadata, swagger_doc)
          requirements = metadata[:operation][:security] || swagger_doc[:security] || []
          scheme_names = requirements.flat_map(&:keys)
          schemes = security_version(scheme_names, swagger_doc)

          schemes.map do |scheme|
            param = (scheme[:type] == :apiKey) ? scheme.slice(:name, :in) : { name: 'Authorization', in: :header }
            param.merge(type: :string, required: requirements.one?)
          end
        end

        def recursively_find_properties(schema, prefix = "", props = {}, depth = 0)
          schema[:properties].each do |property_name, property_schema|
            if property_schema[:properties] && depth < MAX_DEPTH
              prefix += "#{property_name}_"
              recursively_find_properties(property_schema, property_schema[:required], prefix, props, depth + 1)
            else
              props["#{prefix}#{property_name}".to_sym] = {
                schema: property_schema,
                required: schema[:required]&.include?(property_name)
              }
            end
          end
          props
        end

        # Transforms OpenAPI 3 back to Swagger 2 style params to be used by build_form_payload
        # Supports https://swagger.io/docs/specification/describing-request-body/
        def derive_request_body_params(media_type, metadata)
          schema = metadata.dig(:operation, :requestBody, :content, media_type, :schema)
          return {} unless schema

          recursively_find_properties(schema)
        end

        def security_version(scheme_names, swagger_doc)
          if swagger_doc.key?(:securityDefinitions)
            ActiveSupport::Deprecation.warn('Rswag::Specs: WARNING: securityDefinitions is replaced in OpenAPI3! Rename to components/securitySchemes (in swagger_helper.rb)')
            return
          end

          components = swagger_doc[:components] || {}
          (components[:securitySchemes] || {}).slice(*scheme_names).values
        end

        def resolve_parameter(ref, swagger_doc)
          key = key_version(ref, swagger_doc)
          definitions = definition_version(swagger_doc)
          raise "Referenced parameter '#{ref}' must be defined" unless definitions && definitions[key]

          definitions[key]
        end

        def key_version(ref, _swagger_doc)
          if ref.start_with?('#/parameters/')
            ActiveSupport::Deprecation.warn('Rswag::Specs: WARNING: #/parameters/ refs are replaced in OpenAPI3! Rename to #/components/parameters/')
            return
          end

          ref.sub('#/components/parameters/', '').to_sym
        end

        def definition_version(swagger_doc)
          if swagger_doc.key?(:parameters)
            ActiveSupport::Deprecation.warn('Rswag::Specs: WARNING: parameters is replaced in OpenAPI3! Rename to components/parameters (in swagger_helper.rb)')
            return
          end

          components = swagger_doc[:components] || {}
          components[:parameters]
        end

        def base_path_from_servers(swagger_doc, use_server = :default)
          return "" if swagger_doc[:servers].nil? || swagger_doc[:servers].empty?

          server = swagger_doc[:servers].first
          variables = {}
          server.fetch(:variables, {}).each_pair { |k,v| variables[k] = v[use_server] }
          base_path = server[:url].gsub(/\{(.*?)\}/) { |name| variables[name.to_sym] }
          URI(base_path).path
        end

        def add_path(request, metadata, swagger_doc, parameters, example)
          uses_base_path = swagger_doc[:basePath].present?

          if uses_base_path
            ActiveSupport::Deprecation.warn('Rswag::Specs: WARNING: basePath is replaced in OpenAPI3! Update your swagger_helper.rb')
            return
          end

          template = base_path_from_servers(swagger_doc) + metadata[:path_item][:template]

          request[:path] = template.tap do |path_template|
            parameters.select { |p| p[:in] == :path }.each do |p|
              unless example.respond_to?(p[:name])
                raise ArgumentError.new("`#{p[:name].to_s}` parameter key present, but not defined within example group"\
                  "(i. e `it` or `let` block)")
              end
              path_template.gsub!("{#{p[:name]}}", example.send(p[:name]).to_s)
            end

            parameters.select { |p| p[:in] == :query }.each_with_index do |p, i|
              path_template.concat(i.zero? ? '?' : '&')
              path_template.concat(build_query_string_part(p, example.send(p[:name]), swagger_doc))
            end
          end
        end

        # https://swagger.io/docs/specification/serialization/
        def build_query_string_part(param, value, swagger_doc)
          return unless swagger_doc
          return unless param[:schema]

          name = param[:name]

          style = param[:style]&.to_sym || :form
          explode = param[:explode].nil? ? true : param[:explode]

          case param[:schema][:type]&.to_sym
          when :object
            case style
            when :deepObject
              { name => value }.to_query
            when :form
              if explode
                value.to_query
              else
                "#{CGI.escape(name.to_s)}=" + value.to_a.flatten.map { |v| CGI.escape(v.to_s) }.join(',')
              end
            end
          when :array
            case explode
            when true
              value.to_a.flatten.map { |v| "#{CGI.escape(name.to_s)}=#{CGI.escape(v.to_s)}" }.join('&')
            else
              separator = case style
                          when :form then ','
                          when :spaceDelimited then '%20'
                          when :pipeDelimited then '|'
                          end
              "#{CGI.escape(name.to_s)}=" + value.to_a.flatten.map { |v| CGI.escape(v.to_s) }.join(separator)
            end
          else
            "#{name}=#{value}"
          end
        end

        def main_media_type(metadata, _swagger_doc)
          metadata.dig(:operation, :requestBody, :content)&.keys&.first
        end

        # See http://seejohncode.com/2012/04/29/quick-tip-testing-multipart-uploads-with-rspec/
        # Rather that serializing with the appropriate encoding (e.g. multipart/form-data),
        # Rails test infrastructure allows us to send the values directly as a hash
        # PROS: simple to implement, CONS: serialization/deserialization is bypassed in test
        # Ignore inForm parameters as it's for Swagger 2
        def build_form_payload(metadata, _parameters, example)
          tuples = derive_request_body_params('application/x-www-form-urlencoded', metadata)
                   .filter_map do |prop_name, obj|
                     next unless obj[:required]
                     raise(MissingParameterError, prop_name) unless example.respond_to?(prop_name)

                     [prop_name, example.send(prop_name)]
                   end
          Hash[tuples]
        end
      end
    end
  end
end
