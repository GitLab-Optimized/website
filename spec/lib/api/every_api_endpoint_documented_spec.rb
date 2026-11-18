# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Every API endpoint is documented or has a reason', feature_category: :api do
  let(:api_classes) do
    ::API::API # rubocop:disable Lint/Void -- Referenced so every API class is mounted
    ::API::Base.descendants
  end

  let(:undocumented_routes) do
    excluded = Gitlab::GrapeOpenapi.configuration.excluded_api_classes
    documented = Gitlab::GrapeOpenapi.documented_routes(api_classes: api_classes).to_set

    routes = api_classes.reject { |klass| excluded.include?(klass.name) }.flat_map(&:routes)
    routes.reject! do |route|
      documented.include?(route) ||
        route.request_method == '*' ||
        route.settings[:lifecycle] ||
        route.settings[:openapi_hidden_reason]
    end
    routes.map { |route| route_key(route) }.uniq
  end

  it 'documents every route, or records why it is left out' do
    expect(undocumented_routes).to be_empty, <<~MESSAGE
      These API routes are left out of the OpenAPI spec without a reason:
      #{undocumented_routes.sort.map { |key| "- #{key}" }.join("\n")}

      Remove `hidden true` to publish the route, or record why it is hidden.
      See https://docs.gitlab.com/development/api_styleguide/#marking-endpoints-as-hidden.
    MESSAGE
  end

  def route_key(route)
    "#{route.request_method} #{route.path.delete_suffix('(.:format)').delete_prefix('/api/:version')}"
  end
end
