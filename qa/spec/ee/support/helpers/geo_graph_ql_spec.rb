# frozen_string_literal: true

module QA
  RSpec.describe QA::EE::Support::Helpers::GeoGraphQl do
    include described_class

    let(:api_client) { instance_double(QA::Runtime::API::Client) }

    describe '#fetch_secondary_node_id_from_api' do
      let(:request) { instance_double(QA::Runtime::API::Request, url: 'https://example.test/geo_nodes') }

      before do
        allow(QA::Runtime::API::Request).to receive(:new).with(api_client, '/geo_nodes').and_return(request)
        allow(QA::Runtime::Logger).to receive(:info)
        allow(QA::Runtime::Logger).to receive(:error)
      end

      context 'when the API request succeeds' do
        let(:response) { instance_double(RestClient::Response, code: 200, body: '{}') }

        before do
          allow(QA::Support::API).to receive(:get).with(request.url).and_return(response)
          allow(QA::Support::API).to receive(:success?).with(response.code).and_return(true)
          allow(QA::Support::API).to receive(:parse_body).with(response).and_return(nodes)
        end

        context 'and a secondary node is present' do
          let(:nodes) do
            [
              { id: 1, primary: true, name: 'primary' },
              { id: 2, primary: false, name: 'secondary' }
            ]
          end

          it 'returns the secondary node id' do
            expect(fetch_secondary_node_id_from_api(api_client)).to eq(2)
          end

          it 'logs the found secondary node' do
            fetch_secondary_node_id_from_api(api_client)

            expect(QA::Runtime::Logger).to have_received(:info)
              .with(a_string_including('id=2', 'name=secondary'))
          end
        end

        context 'and multiple secondary nodes are present' do
          let(:nodes) do
            [
              { id: 1, primary: true, name: 'primary' },
              { id: 2, primary: false, name: 'secondary-1' },
              { id: 3, primary: false, name: 'secondary-2' }
            ]
          end

          it 'returns the first secondary node id' do
            expect(fetch_secondary_node_id_from_api(api_client)).to eq(2)
          end
        end

        context 'and no secondary node is present' do
          let(:nodes) { [{ id: 1, primary: true, name: 'primary' }] }

          it 'returns nil' do
            expect(fetch_secondary_node_id_from_api(api_client)).to be_nil
          end

          it 'logs an error listing the available node names' do
            fetch_secondary_node_id_from_api(api_client)

            expect(QA::Runtime::Logger).to have_received(:error)
              .with(a_string_including('primary'))
          end
        end
      end

      context 'when the API request fails' do
        let(:response) { instance_double(RestClient::Response, code: 500, body: 'Internal Server Error') }

        before do
          allow(QA::Support::API).to receive(:get).with(request.url).and_return(response)
          allow(QA::Support::API).to receive(:success?).with(response.code).and_return(false)
        end

        it 'returns nil' do
          expect(fetch_secondary_node_id_from_api(api_client)).to be_nil
        end

        it 'logs an error including the response code' do
          fetch_secondary_node_id_from_api(api_client)

          expect(QA::Runtime::Logger).to have_received(:error)
            .with(a_string_including('500'))
        end

        it 'does not attempt to parse the response body' do
          expect(QA::Support::API).not_to receive(:parse_body)

          fetch_secondary_node_id_from_api(api_client)
        end
      end
    end

    describe '#wait_for_project_repository_replication' do
      let(:sync_response) { instance_double(RestClient::Response, code: 200) }
      let(:diagnostic_response) { instance_double(RestClient::Response, code: 200) }
      let(:sync_result) do
        { data: { geoNode: { projectRepositoryRegistries: { nodes: [] } } } }
      end

      let(:diagnostic_result) do
        {
          data: {
            geoNode: {
              projectRepositoryRegistries: {
                nodes: [
                  {
                    projectId: '42',
                    state: 'FAILED',
                    lastSyncFailure: "backend\nfailed",
                    retryCount: 3,
                    lastSyncedAt: nil,
                    retryAt: '2026-11-12T00:00:00Z'
                  }
                ]
              }
            }
          }
        }
      end

      before do
        allow(QA::Runtime::Logger).to receive(:info)
        allow(QA::Runtime::Logger).to receive(:warn)
        allow(QA::Runtime::Logger).to receive(:debug)
        allow(QA::Support::API).to receive(:success?).and_return(true)
        allow(QA::Support::API).to receive(:parse_body) do |response|
          response == sync_response ? sync_result : diagnostic_result
        end
        allow(self).to receive(:geo_graphql_request).and_return(sync_response, diagnostic_response)
        allow(QA::Support::Retrier).to receive(:retry_until) do |**_options, &block|
          block.call
          raise QA::Support::Repeater::WaitExceededError, 'Geo wait timed out'
        end
      end

      it 'logs replication state and retry details after a timeout and preserves the original error' do
        expect do
          wait_for_project_repository_replication(api_client, project_id: 42, max_duration: 1)
        end.to raise_error(QA::Support::Repeater::WaitExceededError, 'Geo wait timed out')

        expect(QA::Runtime::Logger).to have_received(:warn)
          .with(a_string_including('project repository 42', 'FAILED', 'backend failed', 'retry_count', '3'))
        expect(self).to have_received(:geo_graphql_request)
          .with(api_client, a_string_including('projectRepositoryRegistries', 'lastSyncFailure'))
      end

      it 'does not request diagnostics after successful replication' do
        allow(QA::Support::API).to receive(:parse_body)
          .with(sync_response).and_return(
            data: { geoNode: { projectRepositoryRegistries: { nodes: [{ projectId: '42' }] } } }
          )
        allow(QA::Support::Retrier).to receive(:retry_until) { |**_options, &block| block.call }

        expect(wait_for_project_repository_replication(api_client, project_id: 42, max_duration: 1)).to be(true)
        expect(self).to have_received(:geo_graphql_request).once
        expect(QA::Runtime::Logger).not_to have_received(:warn)
      end

      it 'reports a missing registry without claiming the wait succeeded' do
        allow(QA::Support::API).to receive(:parse_body)
          .with(diagnostic_response).and_return(
            data: {
              geoNode: {
                projectRepositoryRegistries: {
                  nodes: []
                }
              }
            }
          )

        expect do
          wait_for_project_repository_replication(api_client, project_id: 42, max_duration: 1)
        end.to raise_error(QA::Support::Repeater::WaitExceededError)

        expect(QA::Runtime::Logger).to have_received(:warn)
          .with(a_string_including('no matching registry in 0 most recent records'))
      end

      it 'preserves the original timeout when the diagnostics request fails' do
        allow(QA::Support::API).to receive(:success?).with(503).and_return(false)
        allow(diagnostic_response).to receive(:code).and_return(503)

        expect do
          wait_for_project_repository_replication(api_client, project_id: 42, max_duration: 1)
        end.to raise_error(QA::Support::Repeater::WaitExceededError, 'Geo wait timed out')

        expect(QA::Runtime::Logger).to have_received(:warn)
          .with(a_string_including('GraphQL HTTP 503'))
      end

      it 'preserves the original timeout when the diagnostics request raises' do
        allow(self).to receive(:geo_graphql_request)
          .and_invoke(->(*) { sync_response }, ->(*) { raise RestClient::Exceptions::OpenTimeout })

        expect do
          wait_for_project_repository_replication(api_client, project_id: 42, max_duration: 1)
        end.to raise_error(QA::Support::Repeater::WaitExceededError, 'Geo wait timed out')

        expect(QA::Runtime::Logger).to have_received(:warn)
          .with(a_string_including('diagnostics unavailable', 'RestClient::Exceptions::OpenTimeout'))
      end

      it 'logs a registry with no last synchronization error without masking the timeout' do
        allow(QA::Support::API).to receive(:parse_body)
          .with(diagnostic_response).and_return(
            data: {
              geoNode: {
                projectRepositoryRegistries: {
                  nodes: [{ projectId: '42', state: 'PENDING', lastSyncFailure: nil, retryCount: 0 }]
                }
              }
            }
          )

        expect do
          wait_for_project_repository_replication(api_client, project_id: 42, max_duration: 1)
        end.to raise_error(QA::Support::Repeater::WaitExceededError, 'Geo wait timed out')

        expect(QA::Runtime::Logger).to have_received(:warn)
          .with(a_string_matching(/PENDING.*last_sync_failure\W+nil/))
      end

      it 'limits timeout diagnostics to a single request when the newest registries do not match' do
        allow(QA::Support::API).to receive(:parse_body)
          .with(diagnostic_response).and_return(
            data: {
              geoNode: {
                projectRepositoryRegistries: {
                  nodes: [{ projectId: '99', state: 'SYNCED' }]
                }
              }
            }
          )

        expect do
          wait_for_project_repository_replication(api_client, project_id: 42, max_duration: 1)
        end.to raise_error(QA::Support::Repeater::WaitExceededError)

        expect(self).to have_received(:geo_graphql_request).twice
        expect(QA::Runtime::Logger).to have_received(:warn)
          .with(a_string_including('no matching registry in 1 most recent records'))
      end
    end
  end
end
