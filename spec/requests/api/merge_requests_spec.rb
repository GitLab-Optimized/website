# frozen_string_literal: true

require 'spec_helper'

RSpec.describe API::MergeRequests, :aggregate_failures, feature_category: :source_code_management do
  include_context 'with merge requests API setup'

  shared_examples 'merge requests list caching' do
    let(:params) { {} }

    before do
      get api(endpoint_path), params: params
    end

    context 'when it is cached' do
      it_behaves_like 'a cached MergeRequest api request'
    end

    context 'when it is not cached' do
      context 'when the status changes' do
        before do
          merge_request.mark_as_unchecked!
        end

        it_behaves_like 'a non-cached MergeRequest api request', 1
      end

      context 'when the label changes' do
        before do
          merge_request.labels << create(:label, project: merge_request.project)
        end

        it_behaves_like 'a non-cached MergeRequest api request', 1
      end

      context 'when "with_labels_details" parameter is provided' do
        let(:params) { { with_labels_details: true } }

        it_behaves_like 'a non-cached MergeRequest api request', 4
      end

      context 'when the assignees change' do
        before do
          merge_request.assignees << create(:user)
        end

        it_behaves_like 'a non-cached MergeRequest api request', 1
      end

      context 'when the reviewers change' do
        before do
          merge_request.reviewers << create(:user)
        end

        it_behaves_like 'a non-cached MergeRequest api request', 1
      end

      context 'when another user requests' do
        before do
          sign_in(user2)
        end

        it_behaves_like 'a non-cached MergeRequest api request', 4
      end
    end
  end

  shared_examples 'merge requests list reusing ListRefs branch heads' do
    def find_commit_calls
      count = 0
      allow(Gitlab::GitalyClient).to receive(:call).and_wrap_original do |method, *args, **kwargs, &block|
        count += 1 if args[2] == :find_commit
        method.call(*args, **kwargs, &block)
      end

      # with_labels_details skips the response cache, so every request serializes
      get api(endpoint_path, user), params: { with_labels_details: true }
      count
    end

    it 'reads source branch heads from ListRefs instead of FindCommit' do
      # Without batched branch heads the conflict check reads each source branch head with FindCommit
      allow(MergeRequests::Mergeability::DetailedMergeStatusService).to receive(:new)
        .and_wrap_original { |method, **kwargs| method.call(**kwargs.merge(batched_branch_heads: false)) }
      calls_without_reuse = find_commit_calls
      statuses = json_response.to_h { |mr| [mr['id'], mr['detailed_merge_status']] }

      allow(MergeRequests::Mergeability::DetailedMergeStatusService).to receive(:new).and_call_original

      expect(find_commit_calls).to be < calls_without_reuse
      expect(json_response.to_h { |mr| [mr['id'], mr['detailed_merge_status']] }).to eq(statuses)
    end
  end

  shared_examples 'merge requests list' do
    it_behaves_like 'issuable API rate-limited search' do
      let(:url) { endpoint_path }
      let(:issuable) { merge_request }
    end

    context 'when unauthenticated' do
      it 'returns merge requests for public projects' do
        get api(endpoint_path)

        expect_successful_response_with_paginated_array
      end
    end

    context 'when authenticated' do
      it 'avoids N+1 queries', :request_store, :use_sql_query_cache do
        create_list(:merge_request, 3, :unique_branches, state: 'closed', milestone: milestone1, author: user, assignees: [user], source_project: project, created_at: base_time)

        control = ActiveRecord::QueryRecorder.new(skip_cached: false) do
          get api(endpoint_path, user)
        end

        create_list(:merge_request, 2, :unique_branches, state: 'closed', milestone: milestone1, author: user, assignees: [user], source_project: project, created_at: base_time)
        merge_request = create(:merge_request, milestone: milestone1, author: user, assignees: [user], source_project: project, target_project: project, title: 'Test 4', created_at: base_time)

        merge_request.metrics.update!(
          merged_by: user,
          latest_closed_by: user,
          latest_closed_at: 1.hour.ago,
          merged_at: 2.hours.ago
        )

        expect do
          get api(endpoint_path, user)
        end.not_to exceed_query_limit(control).allow_skip_cache_inconsistency.with_threshold(allowed_query_threshold)
      end

      context 'when merge requests are merged' do
        it 'avoids N+1 queries', :request_store, :use_sql_query_cache do
          create_list(:merge_request, 3, state: :merged, source_project: project, target_project: project, merge_user: create(:user))

          control = ActiveRecord::QueryRecorder.new(skip_cached: false) do
            get api(endpoint_path, user)
          end

          create_list(:merge_request, 3, state: :merged, source_project: project, target_project: project, merge_user: create(:user))

          expect do
            get api(endpoint_path, user)
          end.not_to exceed_query_limit(control).allow_skip_cache_inconsistency.with_threshold(allowed_query_threshold)
        end
      end

      context 'when merge request is unchecked' do
        let(:check_service_class) { MergeRequests::MergeabilityCheckService }
        let(:mr_entity) { json_response.find { |mr| mr['id'] == merge_request.id } }
        let_it_be_with_reload(:merge_request) { create(:merge_request, :simple, author: user, source_project: project, title: "Test") }

        before do
          merge_request.mark_as_unchecked!
        end

        context 'with a developer+ role' do
          before do
            project.add_developer(user2)
          end

          context 'with merge status recheck protection' do
            it 'checks mergeability asynchronously in batch', :sidekiq_inline do
              get(api(endpoint_path, user2), params: { with_merge_status_recheck: true })

              expect_successful_response_with_paginated_array

              expect(merge_request.reload.merge_status).to eq('can_be_merged')
            end
          end

          context 'without merge status recheck protection' do
            it 'does not enqueue a merge status recheck' do
              expect(check_service_class).not_to receive(:new)

              get api(endpoint_path, user2)

              expect_successful_response_with_paginated_array
              expect(mr_entity['merge_status']).to eq('unchecked')
            end
          end

          context 'with view=simple' do
            it 'does not check mergeability', :sidekiq_inline do
              expect(check_service_class).not_to receive(:new)

              get(api(endpoint_path, user2), params: { view: 'simple' })

              expect_successful_response_with_paginated_array
              expect(merge_request.reload.merge_status).to eq('unchecked')
            end
          end
        end

        context 'with a reporter role' do
          context 'with merge status recheck protection' do
            it 'does not check mergeability', :sidekiq_inline do
              expect(check_service_class).not_to receive(:new)

              get(api(endpoint_path, user2), params: { with_merge_status_recheck: true })

              expect_successful_response_with_paginated_array
              expect(mr_entity['merge_status']).to eq('unchecked')
              expect(merge_request.reload.merge_status).to eq('unchecked')
            end
          end
        end
      end

      context 'with labels' do
        include_context 'with labels'

        it 'returns an array of all merge_requests' do
          get api(endpoint_path, user)

          expect_paginated_array_response(
            [
              merge_request_merged.id,
              merge_request_locked.id,
              merge_request_closed.id,
              merge_request.id
            ])

          expect(json_response.last['title']).to eq(merge_request.title)
          expect(json_response.last).to have_key('web_url')
          expect(json_response.last['sha']).to eq(merge_request.diff_head_sha)
          expect(json_response.last['merge_commit_sha']).to be_nil
          expect(json_response.last['merge_commit_sha']).to eq(merge_request.merge_commit_sha)
          expect(json_response.last['downvotes']).to eq(0)
          expect(json_response.last['upvotes']).to eq(0)
          expect(json_response.last['labels']).to eq([label2.title, label.title])
          expect(json_response.first['title']).to eq(merge_request_merged.title)
          expect(json_response.first['sha']).to eq(merge_request_merged.diff_head_sha)
          expect(json_response.first['merge_commit_sha']).not_to be_nil
          expect(json_response.first['merge_commit_sha']).to eq(merge_request_merged.merge_commit_sha)
        end

        context 'with labels_details' do
          it 'returns labels with details' do
            path = endpoint_path + "?with_labels_details=true"

            get api(path, user)

            expect_successful_response_with_paginated_array
            expect(json_response.last['labels'].pluck('name')).to eq([label2.title, label.title])
            expect(json_response.last['labels'].first).to match_schema('/public_api/v4/label_basic')
          end

          it 'avoids N+1 queries', quarantine: 'https://gitlab.com/gitlab-org/quality/test-failure-issues/-/issues/9318' do
            path = endpoint_path + "?with_labels_details=true"

            control = ActiveRecord::QueryRecorder.new do
              get api(path, user)
            end

            mr = create(:merge_request)
            create(:label_link, label: label, target: mr)
            create(:label_link, label: label2, target: mr)

            expect do
              get api(path, user)
            end.not_to exceed_query_limit(control)
          end
        end
      end

      context 'when DB timeouts occur' do
        it 'returns a :request_timeout status' do
          allow(MergeRequestsFinder).to receive(:new).and_raise(ActiveRecord::QueryCanceled)

          path = endpoint_path + '?view=simple'
          get api(path, user)

          expect(response).to have_gitlab_http_status(:request_timeout)
        end
      end

      it 'returns an array of all merge_requests using simple mode' do
        path = endpoint_path + '?view=simple'

        get api(path, user)

        expect_paginated_array_response(
          [
            merge_request_merged.id,
            merge_request_locked.id,
            merge_request_closed.id,
            merge_request.id
          ])
        expect(json_response.last.keys).to match_array(%w[id iid title web_url created_at description project_id state updated_at])
        expect(json_response.last['iid']).to eq(merge_request.iid)
        expect(json_response.last['title']).to eq(merge_request.title)
        expect(json_response.last).to have_key('web_url')
        expect(json_response.first['iid']).to eq(merge_request_merged.iid)
        expect(json_response.first['title']).to eq(merge_request_merged.title)
        expect(json_response.first).to have_key('web_url')
      end

      it 'matches V4 response schema' do
        get api(endpoint_path, user)

        expect(response).to have_gitlab_http_status(:ok)
        expect(response).to match_response_schema('public_api/v4/merge_requests')
      end
    end
  end

  # The filter logic is the same for the project and group endpoints, so only the project endpoint runs these.
  # The group endpoint compares its results with the project endpoint to cover its own finder query.
  shared_examples 'merge requests list filters' do
    context 'when authenticated' do
      it 'returns an array of open merge_requests' do
        path = endpoint_path + '?state=opened'

        get api(path, user)

        expect_paginated_array_response([merge_request.id])
        expect(json_response.last['title']).to eq(merge_request.title)
      end

      it 'returns an array of closed merge_requests' do
        path = endpoint_path + '?state=closed'

        get api(path, user)

        expect_paginated_array_response([merge_request_closed.id])
        expect(json_response.first['title']).to eq(merge_request_closed.title)
      end

      it 'returns an array of merged merge_requests' do
        path = endpoint_path + '?state=merged'

        get api(path, user)

        expect_paginated_array_response([merge_request_merged.id])
        expect(json_response.first['title']).to eq(merge_request_merged.title)
      end

      it 'returns an empty array if milestone does not exist' do
        get api(endpoint_path, user), params: { milestone: 'foo' }

        expect_empty_array_response
      end

      it 'returns an array of merge requests matching state in milestone' do
        get api(endpoint_path, user), params: { milestone: '0.9', state: 'closed' }

        expect_paginated_array_response([merge_request_closed.id])
        expect(json_response.first['id']).to eq(merge_request_closed.id)
      end

      context 'with labels' do
        include_context 'with labels'

        it 'returns an array of labeled merge requests' do
          path = endpoint_path + "?labels=#{label.title}"

          get api(path, user)

          expect_successful_response_with_paginated_array
          expect(json_response.length).to eq(1)
          expect(json_response.first['labels']).to eq([label2.title, label.title])
        end

        it 'returns an array of labeled merge requests where all labels match' do
          path = endpoint_path + "?labels=#{label.title},foo,bar"

          get api(path, user)

          expect_empty_array_response
        end

        it 'returns an array of labeled merge requests where all labels match' do
          path = endpoint_path + "?labels[]=#{label.title}&labels[]=#{label2.title}"

          get api(path, user)

          expect_successful_response_with_paginated_array
          expect(json_response.length).to eq(1)
          expect(json_response.first['labels']).to eq([label2.title, label.title])
        end

        it 'returns an array of merge requests with any label when filtering by any label' do
          get api(endpoint_path, user), params: { labels: [" #{label.title} ", " #{label2.title} "] }

          expect_paginated_array_response([merge_request.id])
          expect(json_response.first['labels']).to eq([label2.title, label.title])
          expect(json_response.first['id']).to eq(merge_request.id)
        end

        it 'returns an array of merge requests with any label when filtering by any label' do
          get api(endpoint_path, user), params: { labels: ["#{label.title} , #{label2.title}"] }

          expect_paginated_array_response([merge_request.id])
          expect(json_response.first['labels']).to eq([label2.title, label.title])
          expect(json_response.first['id']).to eq(merge_request.id)
        end

        it 'returns an array of merge requests with any label when filtering by any label' do
          get api(endpoint_path, user), params: { labels: IssuableFinder::Params::FILTER_ANY }

          expect_paginated_array_response([merge_request.id])
          expect(json_response.first['id']).to eq(merge_request.id)
        end

        it 'returns an array of merge requests without a label when filtering by no label' do
          get api(endpoint_path, user), params: { labels: IssuableFinder::Params::FILTER_NONE }

          expect_response_contain_exactly(
            merge_request_merged.id, merge_request_locked.id, merge_request_closed.id
          )
        end
      end

      it 'returns an array of labeled merge requests that are merged for a milestone' do
        bug_label = create(:label, title: 'bug', color: '#FFAABB', project: project)

        mr1 = create(:merge_request, state: 'merged', source_project: project, target_project: project, milestone: milestone)
        mr2 = create(:merge_request, state: 'merged', source_project: project, target_project: project, milestone: milestone1)
        mr3 = create(:merge_request, state: 'closed', source_project: project, target_project: project, milestone: milestone1)
        _mr = create(:merge_request, state: 'merged', source_project: project, target_project: project, milestone: milestone1)

        create(:label_link, label: bug_label, target: mr1)
        create(:label_link, label: bug_label, target: mr2)
        create(:label_link, label: bug_label, target: mr3)

        path = endpoint_path + "?labels=#{bug_label.title}&milestone=#{milestone1.title}&state=merged"

        get api(path, user)

        expect_response_contain_exactly(mr2.id)
      end

      context 'with ordering' do
        context '2 merge requests with equal created_at' do
          it 'page breaks first page correctly' do
            get api("#{endpoint_path}?sort=desc&per_page=2", user)

            response_ids = json_response.map { |merge_request| merge_request['id'] }

            expect(response_ids).to contain_exactly(merge_request_merged.id, merge_request_locked.id)
          end

          it 'page breaks second page correctly' do
            get api("#{endpoint_path}?sort=desc&per_page=2&page=2", user)

            response_ids = json_response.map { |merge_request| merge_request['id'] }

            expect(response_ids).to contain_exactly(merge_request_closed.id, merge_request.id)
          end
        end

        it 'returns an array of merge_requests ordered by updated_at' do
          path = endpoint_path + '?order_by=updated_at'

          get api(path, user)

          expect_paginated_array_response(
            [
              merge_request.id,
              merge_request_locked.id,
              merge_request_merged.id,
              merge_request_closed.id
            ])
          response_dates = json_response.map { |merge_request| merge_request['updated_at'] }
          expect(response_dates).to eq(response_dates.sort.reverse)
        end

        it 'returns an array of merge_requests ordered by created_at' do
          path = endpoint_path + '?order_by=created_at&sort=asc'

          get api(path, user)

          expect_paginated_array_response(
            [
              merge_request.id,
              merge_request_closed.id,
              merge_request_locked.id,
              merge_request_merged.id
            ])
          response_dates = json_response.map { |merge_request| merge_request['created_at'] }
          expect(response_dates).to eq(response_dates.sort)
        end

        context 'returns an array of merge_requests ordered by title' do
          it 'asc when requested' do
            path = endpoint_path + '?order_by=title&sort=asc'

            get api(path, user)

            response_titles = json_response.map { |merge_request| merge_request['title'] }
            expect(response_titles).to eq(response_titles.sort)
          end

          it 'desc when requested' do
            path = endpoint_path + '?order_by=title&sort=desc'

            get api(path, user)

            response_titles = json_response.map { |merge_request| merge_request['title'] }
            expect(response_titles).to eq(response_titles.sort.reverse)
          end
        end
      end

      context 'NOT params' do
        let_it_be_with_reload(:milestone) { create(:milestone, title: '1.0.0', project: project) }
        let_it_be(:merge_request2) do
          create(
            :merge_request,
            :simple,
            milestone: milestone,
            author: user,
            assignees: [user],
            reviewers: [user2],
            source_project: project,
            target_project: project,
            source_branch: 'what',
            title: "What",
            created_at: base_time
          )
        end

        let_it_be(:merge_request_context_commit) { create(:merge_request_context_commit, merge_request: merge_request2, message: 'test') }

        before do
          create(:label_link, label: label, target: merge_request)
          create(:label_link, label: label2, target: merge_request2)
        end

        it 'returns merge requests without any of the labels given' do
          get api(endpoint_path, user), params: { not: { labels: ["#{label.title}, #{label2.title}"] } }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response).to be_an(Array)
          expect(json_response.length).to eq(3)
          json_response.each do |mr|
            expect(mr['labels']).not_to include(label2.title, label.title)
          end
        end

        it 'returns merge requests without any of the milestones given' do
          get api(endpoint_path, user), params: { not: { milestone: milestone.title } }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response).to be_an(Array)
          expect(json_response.length).to eq(4)
          json_response.each do |mr|
            expect(mr['milestone']).not_to eq(milestone.title)
          end
        end

        it 'returns merge requests without the author given' do
          get api(endpoint_path, user), params: { not: { author_id: user2.id } }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response).to be_an(Array)
          expect(json_response.length).to eq(5)
          json_response.each do |mr|
            expect(mr['author']['id']).not_to eq(user2.id)
          end
        end

        it 'returns merge requests without the assignee given' do
          get api(endpoint_path, user), params: { not: { assignee_id: user2.id } }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response).to be_an(Array)
          expect(json_response.length).to eq(5)
          json_response.each do |mr|
            expect(mr['assignee']['id']).not_to eq(user2.id)
          end
        end

        context 'filter by reviewer' do
          context 'with reviewer_id' do
            context 'with an id' do
              let(:params) { { not: { reviewer_id: user2.id } } }

              it 'returns merge requests that do not have the given reviewer' do
                get api(endpoint_path, user), params: { not: { reviewer_id: user2.id } }

                expect(response).to have_gitlab_http_status(:ok)
                expect(json_response).to be_an(Array)
                expect(json_response.length).to eq(4)
                expect(json_response.map { |mr| mr['id'] }).not_to include(merge_request2)
              end
            end

            context 'with Any' do
              let(:params) { { not: { reviewer_id: 'Any' } } }

              it 'returns a 400' do
                # Any is not supported for negated filter
                get api(endpoint_path, user), params: params

                expect(response).to have_gitlab_http_status(:bad_request)
                expect(json_response['error']).to eq('not[reviewer_id] is invalid')
              end
            end

            context 'with None' do
              let(:params) { { not: { reviewer_id: 'None' } } }

              it 'returns a 400' do
                # None is not supported for negated filter
                get api(endpoint_path, user), params: params

                expect(response).to have_gitlab_http_status(:bad_request)
                expect(json_response['error']).to eq('not[reviewer_id] is invalid')
              end
            end
          end

          context 'with reviewer_username' do
            let(:params) { { not: { reviewer_username: user2.username } } }

            it 'returns merge requests that do not have the given reviewer' do
              get api(endpoint_path, user), params: params

              expect(response).to have_gitlab_http_status(:ok)
              expect(json_response).to be_an(Array)
              expect(json_response.length).to eq(4)
              expect(json_response.map { |mr| mr['id'] }).not_to include(merge_request2)
            end
          end

          context 'when both reviewer_id and reviewer_username' do
            let(:params) { { not: { reviewer_id: user2.id, reviewer_username: user2.username } } }

            it 'returns a 400' do
              get api('/merge_requests', user), params: params

              expect(response).to have_gitlab_http_status(:bad_request)
              expect(json_response['error']).to eq('not[reviewer_id], not[reviewer_username] are mutually exclusive')
            end
          end
        end
      end

      context 'source_branch param' do
        it 'returns merge requests with the given source branch' do
          get api(endpoint_path, user), params: { source_branch: merge_request_closed.source_branch, state: 'all' }

          expect_response_contain_exactly(
            merge_request_merged.id, merge_request_locked.id, merge_request_closed.id
          )
        end
      end

      context 'target_branch param' do
        it 'returns merge requests with the given target branch' do
          get api(endpoint_path, user), params: { target_branch: merge_request_closed.target_branch, state: 'all' }

          expect_response_contain_exactly(
            merge_request_merged.id, merge_request_locked.id, merge_request_closed.id
          )
        end
      end
    end
  end

  RSpec.shared_examples 'a non-cached MergeRequest api request' do |call_count|
    it 'serializes merge request' do
      expect(API::Entities::MergeRequestBasic).to receive(:represent).exactly(call_count).times.and_call_original

      get api(endpoint_path)
    end
  end

  RSpec.shared_examples 'a cached MergeRequest api request' do
    it 'serializes merge request' do
      expect(API::Entities::MergeRequestBasic).not_to receive(:represent)

      get api(endpoint_path)
    end
  end

  describe 'route shadowing' do
    include GrapePathHelpers::NamedRouteMatcher

    it 'does not occur' do
      path = api_v4_projects_merge_requests_path(id: 1)
      expect(path).to eq('/api/v4/projects/1/merge_requests')

      path = api_v4_projects_merge_requests_path(id: 1, merge_request_iid: 3)
      expect(path).to eq('/api/v4/projects/1/merge_requests/3')
    end
  end

  describe 'GET /merge_requests' do
    include_context 'with merge requests'

    it_behaves_like 'merge requests list reusing ListRefs branch heads' do
      let(:endpoint_path) { '/merge_requests' }
    end

    context 'with bot authors' do
      let_it_be(:bot_author) { create(:user, :project_bot) }
      let_it_be(:bot_merge_request) do
        create(:merge_request, :simple, source_project: project, target_project: project, author: bot_author)
      end

      it 'includes bot status for human and bot authors' do
        get api('/merge_requests', user), params: { scope: 'all' }

        expect(response).to have_gitlab_http_status(:ok)
        expect(response).to match_response_schema('public_api/v4/merge_requests')
        expect(json_response).to include(
          a_hash_including('id' => merge_request.id, 'author' => a_hash_including('bot' => false)),
          a_hash_including('id' => bot_merge_request.id, 'author' => a_hash_including('bot' => true))
        )
      end

      it 'avoids N+1 queries when serializing bot authors', :request_store, :use_sql_query_cache do
        get api('/merge_requests', user), params: { scope: 'all' }

        control = ActiveRecord::QueryRecorder.new(skip_cached: false) do
          get api('/merge_requests', user), params: { scope: 'all' }
        end

        create_list(:merge_request, 3, :simple, :closed, source_project: project, target_project: project,
          author: create(:user, :service_account))

        expect do
          get api('/merge_requests', user), params: { scope: 'all' }
        end.not_to exceed_all_query_limit(control).with_threshold(allowed_query_threshold)
      end
    end

    it_behaves_like 'issuable API rate-limited search' do
      let(:url) { '/merge_requests' }
      let(:issuable) { merge_request }
    end

    context 'when unauthenticated' do
      it 'returns an array of all merge requests' do
        get api('/merge_requests'), params: { scope: 'all' }

        expect_response_contain_exactly(
          merge_request_merged.id, merge_request_locked.id,
          merge_request_closed.id, merge_request.id
        )
      end

      it "returns authentication error without any scope" do
        get api("/merge_requests")

        expect(response).to have_gitlab_http_status(:unauthorized)
      end

      it "returns authentication error when scope is assigned-to-me" do
        get api("/merge_requests"), params: { scope: 'assigned-to-me' }

        expect(response).to have_gitlab_http_status(:unauthorized)
      end

      it "returns authentication error when scope is assigned_to_me" do
        get api("/merge_requests"), params: { scope: 'assigned_to_me' }

        expect(response).to have_gitlab_http_status(:unauthorized)
      end

      it "returns authentication error when scope is reviews_for_me" do
        get api("/merge_requests"), params: { scope: 'reviews_for_me' }

        expect(response).to have_gitlab_http_status(:unauthorized)
      end

      it "returns authentication error when scope is created-by-me" do
        get api("/merge_requests"), params: { scope: 'created-by-me' }

        expect(response).to have_gitlab_http_status(:unauthorized)
      end
    end

    context 'when authenticated' do
      let_it_be(:project2, freeze: false) { create(:project, :public, :repository, namespace: user.namespace) }
      let_it_be(:merge_request2) { create(:merge_request, :simple, author: user, assignees: [user], source_project: project2, target_project: project2) }
      let_it_be(:user2, freeze: false) { create(:user) }

      it "returns an array of no merge_requests when wip=yes" do
        get api("/merge_requests", user), params: { wip: 'yes' }

        expect_empty_array_response
      end

      it "returns an array of no merge_requests when wip=no" do
        get api("/merge_requests", user), params: { wip: 'no' }

        expect_response_contain_exactly(
          merge_request_merged.id, merge_request2.id, merge_request_locked.id,
          merge_request_closed.id, merge_request.id
        )
      end

      context 'with draft parameter' do
        let_it_be(:draft_mr) { create(:merge_request, :draft_merge_request, author: user, source_project: project2, target_project: project2) }

        it 'returns only draft merge requests when draft=true' do
          get api('/merge_requests', user), params: { draft: true }

          expect_response_contain_exactly(draft_mr.id)
        end

        it 'returns only non-draft merge requests when draft=false' do
          get api('/merge_requests', user), params: { draft: false }

          expect_response_contain_exactly(
            merge_request_merged.id, merge_request2.id, merge_request_locked.id,
            merge_request_closed.id, merge_request.id
          )
        end

        it 'returns 400 when both draft and wip are specified' do
          get api('/merge_requests', user), params: { draft: true, wip: 'yes' }

          expect(response).to have_gitlab_http_status(:bad_request)
        end
      end

      it 'does not return unauthorized merge requests' do
        private_project = create(:project, :private)
        merge_request3 = create(:merge_request, :simple, source_project: private_project, target_project: private_project, source_branch: 'other-branch')

        get api('/merge_requests', user), params: { scope: :all }

        expect_response_contain_exactly(
          merge_request_merged.id, merge_request2.id, merge_request_locked.id,
          merge_request_closed.id, merge_request.id
        )
        expect(json_response.map { |mr| mr['id'] }).not_to include(merge_request3.id)
      end

      it 'returns an array of merge requests created by current user if no scope is given' do
        merge_request3 = create(:merge_request, :simple, author: user2, assignees: [user], source_project: project2, target_project: project2, source_branch: 'other-branch')

        get api('/merge_requests', user2)

        expect_response_contain_exactly(merge_request3.id)
      end

      context 'filter by author' do
        let_it_be_with_reload(:user3) { create(:user) }
        let_it_be_with_reload(:project) { create(:project, :public, :repository, creator: user3, namespace: user3.namespace, only_allow_merge_if_pipeline_succeeds: false) }
        let_it_be_with_reload(:merge_request3) do
          create(:merge_request, :simple, author: user3, assignees: [user3], source_project: project, target_project: project, source_branch: 'other-branch')
        end

        context 'when only `author_id` is passed' do
          it 'returns an array of merge requests authored by the given user' do
            get api('/merge_requests', user), params: {
              author_id: user3.id,
              scope: :all
            }

            expect_response_contain_exactly(merge_request3.id)
          end
        end

        context 'when only `author_username` is passed' do
          it 'returns an array of merge requests authored by the given user(by `author_username`)' do
            get api('/merge_requests', user), params: {
              author_username: user3.username,
              scope: :all
            }

            expect_response_contain_exactly(merge_request3.id)
          end
        end

        context 'when both `author_id` and `author_username` are passed' do
          it 'returns a 400' do
            get api('/merge_requests', user), params: {
              author_id: user.id,
              author_username: user2.username,
              scope: :all
            }

            expect(response).to have_gitlab_http_status(:bad_request)
            expect(json_response['error']).to eq(
              'author_id, author_username are mutually exclusive')
          end
        end
      end

      context 'filter by reviewer' do
        let_it_be(:review_requested_mr1, freeze: false) do
          create(:merge_request, :unique_branches, author: user, reviewers: [user2], source_project: project2, target_project: project2)
        end

        let_it_be(:review_requested_mr2) do
          create(:merge_request, :unique_branches, author: user2, reviewers: [user], source_project: project2, target_project: project2)
        end

        let(:params) { { scope: :all } }

        context 'with reviewer_id' do
          let(:params) { super().merge(reviewer_id: reviewer_id) }

          context 'with an id' do
            let(:reviewer_id) { user2.id }

            it 'returns review requested merge requests for the given user' do
              get api('/merge_requests', user), params: params

              expect_response_contain_exactly(review_requested_mr1.id)
            end
          end

          context 'with Any' do
            let(:reviewer_id) { 'Any' }

            it 'returns review requested merge requests for any user' do
              get api('/merge_requests', user), params: params

              expect_response_contain_exactly(review_requested_mr1.id, review_requested_mr2.id)
            end
          end

          context 'with None' do
            let(:reviewer_id) { 'None' }

            it 'returns merge requests that has no assigned reviewers' do
              get api('/merge_requests', user), params: params

              expect_response_contain_exactly(
                merge_request.id,
                merge_request_closed.id,
                merge_request_merged.id,
                merge_request_locked.id,
                merge_request2.id
              )
            end
          end
        end

        context 'with reviewer_username' do
          let(:params) { super().merge(reviewer_username: user2.username) }

          it 'returns review requested merge requests for the given user' do
            get api('/merge_requests', user), params: params

            expect_response_contain_exactly(review_requested_mr1.id)
          end
        end

        context 'with both reviewer_id and reviewer_username' do
          let(:params) { super().merge(reviewer_id: user2.id, reviewer_username: user2.username) }

          it 'returns a 400' do
            get api('/merge_requests', user), params: params

            expect(response).to have_gitlab_http_status(:bad_request)
            expect(json_response['error']).to eq('reviewer_id, reviewer_username are mutually exclusive')
          end
        end
      end

      context 'filter by merge_user' do
        let(:params) { { scope: :all } }

        context 'with merge_user_id' do
          let(:params) { super().merge(merge_user_id: user.id) }

          it 'returns merged merge requests for the given user' do
            get api('/merge_requests', user), params: params

            expect_response_contain_exactly(merge_request_merged.id)
          end
        end

        context 'with merge_user_username' do
          let(:params) { super().merge(merge_user_username: user.username) }

          it 'returns merged merge requests for the given user' do
            get api('/merge_requests', user), params: params

            expect_response_contain_exactly(merge_request_merged.id)
          end
        end

        context 'with both merge_user_id and merge_user_username' do
          let(:params) { super().merge(merge_user_id: user.id, merge_user_username: user.username) }

          it 'returns a 400' do
            get api('/merge_requests', user), params: params

            expect(response).to have_gitlab_http_status(:bad_request)
            expect(json_response['error']).to eq('merge_user_id, merge_user_username are mutually exclusive')
          end
        end
      end

      it 'returns an array of merge requests assigned to the given user' do
        merge_request3 = create(:merge_request, :simple, author: user, assignees: [user2], source_project: project2, target_project: project2, source_branch: 'other-branch')

        get api('/merge_requests', user), params: { assignee_id: user2.id, scope: :all }

        expect_response_contain_exactly(merge_request3.id)
      end

      it 'returns an array of merge requests with no assignee' do
        merge_request3 = create(:merge_request, :simple, author: user, source_project: project2, target_project: project2, source_branch: 'other-branch')

        get api('/merge_requests', user), params: { assignee_id: 'None', scope: :all }

        expect_response_contain_exactly(merge_request3.id)
      end

      it 'returns an array of merge requests with any assignee' do
        # This MR with no assignee should not be returned
        create(:merge_request, :simple, author: user, source_project: project2, target_project: project2, source_branch: 'other-branch')

        get api('/merge_requests', user), params: { assignee_id: 'Any', scope: :all }

        expect_response_contain_exactly(
          merge_request_merged.id, merge_request2.id, merge_request_locked.id,
          merge_request_closed.id, merge_request.id
        )
      end

      it 'returns an array of merge requests assigned to me' do
        merge_request3 = create(:merge_request, :simple, author: user, assignees: [user2], source_project: project2, target_project: project2, source_branch: 'other-branch')

        get api('/merge_requests', user2), params: { scope: 'assigned_to_me' }

        expect_response_contain_exactly(merge_request3.id)
      end

      it 'returns an array of merge requests assigned to me (kebab-case)' do
        merge_request3 = create(:merge_request, :simple, author: user, assignees: [user2], source_project: project2, target_project: project2, source_branch: 'other-branch')

        get api('/merge_requests', user2), params: { scope: 'assigned-to-me' }

        expect_response_contain_exactly(merge_request3.id)
      end

      it 'returns an array of merge requests created by me' do
        merge_request3 = create(:merge_request, :simple, author: user2, assignees: [user], source_project: project2, target_project: project2, source_branch: 'other-branch')

        get api('/merge_requests', user2), params: { scope: 'created_by_me' }

        expect_response_contain_exactly(merge_request3.id)
      end

      it 'returns an array of merge requests created by me (kebab-case)' do
        merge_request3 = create(:merge_request, :simple, author: user2, assignees: [user], source_project: project2, target_project: project2, source_branch: 'other-branch')

        get api('/merge_requests', user2), params: { scope: 'created-by-me' }

        expect_response_contain_exactly(merge_request3.id)
      end

      it 'returns an array of merge requests where I am a reviewer' do
        # Create a merge request where user2 is a reviewer
        merge_request3 = create(:merge_request, :simple, author: user, source_project: project2, target_project: project2, source_branch: 'other-branch')
        merge_request3.update!(reviewer_ids: [user2.id])

        # Create a merge request where someone else is a reviewer (should not be returned)
        merge_request4 = create(:merge_request, :simple, author: user, source_project: project2, target_project: project2, source_branch: 'another-branch')
        merge_request4.update!(reviewer_ids: [user.id])

        # Create a merge request with no reviewers (should not be returned)
        create(:merge_request, :simple, author: user, source_project: project2, target_project: project2, source_branch: 'no-reviewer-branch')

        get api('/merge_requests', user2), params: { scope: 'reviews_for_me' }

        # Should only return the merge request where user2 is a reviewer
        expect_response_contain_exactly(merge_request3.id)
      end

      it 'returns merge requests reacted by the authenticated user by the given emoji' do
        merge_request3 = create(:merge_request, :simple, author: user, assignees: [user], source_project: project2, target_project: project2, source_branch: 'other-branch')
        award_emoji = create(:award_emoji, awardable: merge_request3, user: user2, name: 'star')

        get api('/merge_requests', user2), params: { my_reaction_emoji: award_emoji.name, scope: 'all' }

        expect_response_contain_exactly(merge_request3.id)
      end

      context 'source_branch param' do
        it 'returns merge requests with the given source branch' do
          get api('/merge_requests', user), params: { source_branch: merge_request_closed.source_branch, state: 'all' }

          expect_response_contain_exactly(
            merge_request_merged.id, merge_request_locked.id, merge_request_closed.id
          )
        end
      end

      context 'target_branch param' do
        it 'returns merge requests with the given target branch' do
          get api('/merge_requests', user), params: { target_branch: merge_request_closed.target_branch, state: 'all' }

          expect_response_contain_exactly(
            merge_request_merged.id, merge_request_locked.id, merge_request_closed.id
          )
        end
      end

      context 'with non_archived parameter' do
        let_it_be(:archived_project) { create(:project, :public, :archived, namespace: user.namespace) }
        let_it_be(:archived_merge_request) { create(:merge_request, :simple, author: user, source_project: archived_project) }

        it 'returns merge requests including archived projects by default' do
          get api('/merge_requests', user), params: { scope: 'all' }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response).to be_an Array
          expect(json_response.map { |mr| mr['id'] }).to include(archived_merge_request.id)
          expect(json_response.map { |mr| mr['id'] }).to include(merge_request.id)
        end

        it 'returns merge requests from non-archived projects only when non_archived is true' do
          get api('/merge_requests', user), params: { non_archived: true, scope: 'all' }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response).to be_an Array
          expect(json_response.map { |mr| mr['id'] }).not_to include(archived_merge_request.id)
          expect(json_response.map { |mr| mr['id'] }).to include(merge_request.id)
        end

        it 'returns merge requests from archived projects when non_archived is false' do
          get api('/merge_requests', user), params: { non_archived: false, scope: 'all' }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response).to be_an Array
          expect(json_response.map { |mr| mr['id'] }).to include(archived_merge_request.id)
          expect(json_response.map { |mr| mr['id'] }).to include(merge_request.id)
        end
      end

      it 'returns merge requests created before a specific date' do
        merge_request2 = create(:merge_request, :simple, source_project: project, target_project: project, source_branch: 'feature_1', created_at: Date.new(2000, 1, 1))

        get api('/merge_requests?created_before=2000-01-02T00:00:00.060Z', user)

        expect_response_contain_exactly(merge_request2.id)
      end

      it 'returns merge requests created after a specific date' do
        merge_request2 = create(:merge_request, :simple, source_project: project, target_project: project, source_branch: 'feature_1', created_at: 1.week.from_now)

        get api("/merge_requests?created_after=#{merge_request2.created_at}", user)

        expect_response_contain_exactly(merge_request2.id)
      end

      it 'returns merge requests updated before a specific date' do
        merge_request2 = create(:merge_request, :simple, source_project: project, target_project: project, source_branch: 'feature_1', updated_at: Date.new(2000, 1, 1))

        get api('/merge_requests?updated_before=2000-01-02T00:00:00.060Z', user)

        expect_response_contain_exactly(merge_request2.id)
      end

      it 'returns merge requests updated after a specific date' do
        merge_request2 = create(:merge_request, :simple, source_project: project, target_project: project, source_branch: 'feature_1', updated_at: 1.week.from_now)

        get api("/merge_requests?updated_after=#{merge_request2.updated_at}", user)

        expect_response_contain_exactly(merge_request2.id)
      end

      it 'returns merge requests merged before a specific date' do
        merge_request2 = create(:merge_request, :merged, source_project: project, target_project: project)

        merge_request2.metrics.update!(merged_at: Date.new(2000, 1, 1))

        get api('/merge_requests?merged_before=2000-01-02T00:00:00.060Z', user)

        expect_response_contain_exactly(merge_request2.id)
      end

      it 'returns merge requests merged after a specific date' do
        merge_request2 = create(:merge_request, :merged, source_project: project, target_project: project)

        merge_request2.metrics.update!(merged_at: 1.week.from_now)

        get api("/merge_requests?merged_after=#{merge_request2.metrics.merged_at}", user)

        expect_response_contain_exactly(merge_request2.id)
      end

      context 'search params' do
        let_it_be(:merge_request, freeze: false) do
          create(:merge_request, :simple, author: user, source_project: project, target_project: project, title: 'Search title', description: 'Search description')
        end

        it 'returns merge requests matching given search string for title' do
          get api("/merge_requests", user), params: { search: merge_request.title }

          expect_response_contain_exactly(merge_request.id)
        end

        it 'returns merge requests matching given search string for title and scoped in title' do
          get api("/merge_requests", user), params: { search: merge_request.title, in: 'title' }

          expect_response_contain_exactly(merge_request.id)
        end

        it 'returns an empty array if no merge request matches given search string for description and scoped in title' do
          get api("/merge_requests", user), params: { search: merge_request.description, in: 'title' }

          expect_empty_array_response
        end

        it 'returns merge requests for project matching given search string for description' do
          get api("/merge_requests", user), params: { project_id: project.id, search: merge_request.description }

          expect_response_contain_exactly(merge_request.id)
        end
      end

      context 'state param' do
        it 'returns merge requests with the given state' do
          get api('/merge_requests', user), params: { state: 'locked' }

          expect_response_contain_exactly(merge_request_locked.id)
        end
      end

      it_behaves_like 'authorizing granular token permissions', :read_merge_request do
        let(:boundary_object) { :user }
        let(:request) do
          get api('/merge_requests', personal_access_token: pat), params: { scope: 'all' }
        end
      end
    end

    context 'when merge requests are filtered by authorization' do
      let_it_be(:filter_user) { create(:user) }
      let_it_be(:filter_group) { create(:group) }
      let_it_be(:filter_project) do
        create(:project, :repository, namespace: filter_group, developers: [filter_user])
      end

      let_it_be(:restricted_mr) do
        create(:merge_request, :simple, source_project: filter_project, target_project: filter_project,
          author: filter_user, source_branch: 'restricted-branch')
      end

      let_it_be(:unrestricted_mr) do
        create(:merge_request, :simple, source_project: filter_project, target_project: filter_project,
          author: filter_user, source_branch: 'unrestricted-branch')
      end

      context 'when unauthorized merge requests are not filtered out' do
        it 'includes all merge requests' do
          get api('/merge_requests', filter_user), params: { scope: 'created_by_me' }

          expect_response_contain_exactly(restricted_mr.id, unrestricted_mr.id)
        end
      end

      context 'when Ability filters out unauthorized merge requests' do
        before do
          allow(Ability).to receive(:merge_requests_readable_by_user).and_return([unrestricted_mr])
        end

        it 'includes only authorized merge requests' do
          get api('/merge_requests', filter_user), params: { scope: 'created_by_me' }

          expect_response_contain_exactly(unrestricted_mr.id)
        end
      end
    end
  end

  describe "GET /projects/:id/merge_requests", :use_clean_rails_memory_store_caching do
    include_context 'with merge requests'

    let(:endpoint_path) { "/projects/#{project.id}/merge_requests" }

    it_behaves_like 'enforcing job token policies', :read_merge_requests,
      allow_public_access_for_enabled_project_features: [:repository, :merge_requests] do
      let(:request) do
        get api(endpoint_path), params: { job_token: target_job.token }
      end
    end

    it_behaves_like 'authorizing granular token permissions', :read_merge_request do
      let(:boundary_object) { project }
      let(:request) do
        get api("/projects/#{project.id}/merge_requests", personal_access_token: pat)
      end
    end

    it_behaves_like 'merge requests list'
    it_behaves_like 'merge requests list filters'
    it_behaves_like 'merge requests list reusing ListRefs branch heads'

    context 'caching' do
      it_behaves_like 'merge requests list caching'
    end

    it "returns 404 for non public projects" do
      project = create(:project, :private)

      get api("/projects/#{project.id}/merge_requests")

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it "returns an array of no merge_requests when wip=yes" do
      get api("/projects/#{project.id}/merge_requests", user), params: { wip: 'yes' }

      expect_empty_array_response
    end

    context 'with draft parameter' do
      let_it_be(:draft_mr) { create(:merge_request, :draft_merge_request, author: user, source_project: project, target_project: project) }

      it 'returns only draft merge requests when draft=true' do
        get api("/projects/#{project.id}/merge_requests", user), params: { draft: true }

        expect_response_contain_exactly(draft_mr.id)
      end

      it 'returns only non-draft merge requests when draft=false' do
        get api("/projects/#{project.id}/merge_requests", user), params: { draft: false }

        expect(json_response).not_to include(a_hash_including('id' => draft_mr.id))
        expect(response).to have_gitlab_http_status(:ok)
      end

      it 'returns 400 when both draft and wip are specified' do
        get api("/projects/#{project.id}/merge_requests", user), params: { draft: true, wip: 'yes' }

        expect(response).to have_gitlab_http_status(:bad_request)
      end
    end

    it 'returns merge_request by "iids" array' do
      get api(endpoint_path, user), params: { iids: [merge_request.iid, merge_request_closed.iid] }

      expect_paginated_array_response([merge_request_closed.id, merge_request.id])
      expect(json_response.first['title']).to eq merge_request_closed.title
      expect(json_response.first['id']).to eq merge_request_closed.id
    end

    context 'when filtering by deployments' do
      let_it_be(:mr) do
        create(:merge_request, :merged, source_project: project, target_project: project)
      end

      before do
        env = create(:environment, project: project, name: 'staging')
        deploy = create(:deployment, :success, environment: env, deployable: nil)

        deploy.link_merge_requests(MergeRequest.where(id: mr.id))
      end

      it 'supports getting merge requests deployed to an environment' do
        get api(endpoint_path, user), params: { environment: 'staging' }

        expect(json_response.first['id']).to eq mr.id
      end

      it 'does not return merge requests for an environment without deployments' do
        get api(endpoint_path, user), params: { environment: 'bla' }

        expect_empty_array_response
      end

      it 'supports getting merge requests deployed after a date' do
        get api(endpoint_path, user), params: { deployed_after: '1990-01-01' }

        expect(json_response.first['id']).to eq mr.id
      end

      it 'does not return merge requests not deployed after a given date' do
        get api(endpoint_path, user), params: { deployed_after: '2100-01-01' }

        expect_empty_array_response
      end

      it 'supports getting merge requests deployed before a date' do
        get api(endpoint_path, user), params: { deployed_before: '2100-01-01' }

        expect(json_response.first['id']).to eq mr.id
      end

      it 'does not return merge requests not deployed before a given date' do
        get api(endpoint_path, user), params: { deployed_before: '1990-01-01' }

        expect_empty_array_response
      end

      it 'returns 400 when deployed_before is not a valid date' do
        get api(endpoint_path, user), params: { deployed_before: '2021-99-99' }

        expect(response).to have_gitlab_http_status(:bad_request)
      end

      it 'returns 400 when deployed_after is not a valid date' do
        get api(endpoint_path, user), params: { deployed_after: '2021-99-99' }

        expect(response).to have_gitlab_http_status(:bad_request)
      end
    end

    context 'a project which enforces all discussions to be resolved' do
      let_it_be(:project) do
        create(:project, :repository, only_allow_merge_if_all_discussions_are_resolved: true, reporters: user)
      end

      include_context 'with merge requests'

      it 'avoids N+1 queries', quarantine: 'https://gitlab.com/gitlab-org/quality/test-failure-issues/-/issues/9318' do
        control = ActiveRecord::QueryRecorder.new do
          get api("/projects/#{project.id}/merge_requests", user)
        end

        create(:merge_request, author: user, assignees: [user], source_project: project, target_project: project, created_at: base_time)

        expect do
          get api("/projects/#{project.id}/merge_requests", user)
        end.not_to exceed_query_limit(control)
      end
    end

    context 'when user is an inherited member from the group' do
      let_it_be(:group) { create(:group) }

      shared_examples 'user cannot view merge requests' do
        it 'returns 403 forbidden' do
          get api("/projects/#{group_project.id}/merge_requests", inherited_user)

          expect(response).to have_gitlab_http_status(:forbidden)
        end
      end

      context 'and user is a guest' do
        let_it_be(:inherited_user) { create(:user) }

        before_all do
          group.add_guest(inherited_user)
        end

        context 'when project is public with private merge requests' do
          let_it_be(:group_project) do
            create(
              :project,
              :public,
              group: group,
              merge_requests_access_level: ProjectFeature::DISABLED
            )
          end

          it_behaves_like 'user cannot view merge requests'
        end

        context 'when project is private' do
          let_it_be(:group_project) { create(:project, :private, group: group) }

          it_behaves_like 'user cannot view merge requests'
        end
      end
    end
  end

  describe "GET /groups/:id/merge_requests" do
    let_it_be_with_reload(:group) { create(:group, :public) }
    let_it_be(:project) { create(:project, :public, :repository, creator: user, namespace: group, only_allow_merge_if_pipeline_succeeds: false) }
    let(:endpoint_path) { "/groups/#{group.id}/merge_requests" }

    include_context 'with merge requests'

    before do
      group.add_reporter(user)
    end

    it_behaves_like 'merge requests list'
    it_behaves_like 'merge requests list reusing ListRefs branch heads'

    context 'with filters and sort orders' do
      include_context 'with labels'

      it 'returns the same merge requests in the same order as the project endpoint' do
        [
          { labels: label.title },
          { milestone: milestone1.title, state: 'closed' },
          { not: { labels: label.title } },
          { source_branch: merge_request_closed.source_branch },
          { order_by: 'created_at', sort: 'asc' },
          { order_by: 'updated_at', sort: 'desc' },
          { order_by: 'title', sort: 'asc' },
          { order_by: 'merged_at', sort: 'desc', state: 'merged' },
          { sort: 'desc', per_page: 2, page: 2 }
        ].each do |params|
          get api("/projects/#{project.id}/merge_requests", user), params: params
          project_ids = json_response.pluck('id')

          get api(endpoint_path, user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(project_ids).not_to be_empty
          expect(json_response.pluck('id')).to eq(project_ids), "params: #{params}"
        end
      end
    end

    describe 'total count cache', :use_clean_rails_memory_store_caching do
      let(:count_query) { /SELECT COUNT\(\*\) FROM \(SELECT 1 AS one FROM "merge_requests"/ }

      def list_merge_requests(as: user, **params)
        ActiveRecord::QueryRecorder.new { get api(endpoint_path, as), params: { per_page: 1, **params } }.log
      end

      it 'reuses the count from an earlier request for the same query' do
        list_merge_requests(page: 2)
        total = response.headers['X-Total']

        expect(list_merge_requests(page: 3)).not_to include(a_string_matching(count_query))
        expect(response.headers['X-Total']).to eq(total)
      end

      it 'reuses the count when only serialization params change' do
        list_merge_requests(page: 2)

        expect(list_merge_requests(page: 3, with_labels_details: true)).not_to include(a_string_matching(count_query))
      end

      it 'counts again for another user or other filters' do
        list_merge_requests(page: 2)

        expect(list_merge_requests(as: user2, page: 3)).to include(a_string_matching(count_query))
        expect(list_merge_requests(state: 'opened', page: 3)).to include(a_string_matching(count_query))
      end
    end

    context 'when have subgroups' do
      let_it_be(:subgroup) { create(:group, :public, parent: group) }
      let_it_be(:subgroup_project) { create(:project, :public, namespace: subgroup) }
      let_it_be(:subgroup_label) { create(:label, project: subgroup_project) }
      let_it_be(:subgroup_merge_request) do
        create(:labeled_merge_request, labels: [subgroup_label], author: user, source_project: subgroup_project, target_project: subgroup_project)
      end

      it 'returns merge requests from projects in the group and its subgroups' do
        get api(endpoint_path, user)

        expect_response_contain_exactly(
          merge_request_merged.id, merge_request_locked.id, merge_request_closed.id,
          merge_request.id, subgroup_merge_request.id
        )
      end

      it 'filters by a label of a project in a subgroup' do
        get api(endpoint_path, user), params: { labels: subgroup_label.title }

        expect_response_contain_exactly(subgroup_merge_request.id)
      end
    end

    describe "#to_reference" do
      it 'exposes reference path in context of group' do
        get api("/groups/#{group.id}/merge_requests", user)

        expect(json_response.first['references']['short']).to eq("!#{merge_request_merged.iid}")
        expect(json_response.first['references']['relative']).to eq("#{merge_request_merged.target_project.path}!#{merge_request_merged.iid}")
        expect(json_response.first['references']['full']).to eq("#{merge_request_merged.target_project.full_path}!#{merge_request_merged.iid}")
      end

      context 'referencing from parent group' do
        let(:parent_group) { create(:group) }

        before do
          group.update!(parent_id: parent_group.id)
          merge_request_merged.reload
        end

        it 'exposes reference path in context of parent group' do
          get api("/groups/#{parent_group.id}/merge_requests")

          expect(json_response.first['references']['short']).to eq("!#{merge_request_merged.iid}")
          expect(json_response.first['references']['relative']).to eq("#{merge_request_merged.target_project.full_path}!#{merge_request_merged.iid}")
          expect(json_response.first['references']['full']).to eq("#{merge_request_merged.target_project.full_path}!#{merge_request_merged.iid}")
        end
      end
    end

    context 'with archived projects' do
      let_it_be(:project2) { create(:project, :public, :archived, namespace: group) }
      let_it_be(:merge_request_archived) { create(:merge_request, title: 'archived mr', author: user, source_project: project2, target_project: project2) }

      it 'returns an array excluding merge_requests from archived projects' do
        get api(endpoint_path, user)

        expect_response_contain_exactly(
          merge_request_merged.id, merge_request_locked.id,
          merge_request_closed.id, merge_request.id
        )
      end

      context 'with non_archived param set as false' do
        it 'returns an array including merge_requests from archived projects' do
          path = endpoint_path + '?non_archived=false'

          get api(path, user)

          expect_response_contain_exactly(
            merge_request_merged.id, merge_request_archived.id, merge_request_locked.id,
            merge_request_closed.id, merge_request.id
          )
        end
      end
    end

    it_behaves_like 'authorizing granular token permissions', :read_merge_request do
      let(:boundary_object) { Group.find(group.id) }
      let(:request) do
        get api(endpoint_path, personal_access_token: pat)
      end
    end
  end

  describe 'PUT /projects/:id/merge_requests/:merge_request_iid' do
    context 'with one merge request for all examples' do
      include_context 'with a merge request created once'

      it_behaves_like 'issuable update endpoint' do
        let(:entity) { merge_request }
      end

      describe 'mcp route setting' do
        subject do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
            params: { title: 'Updated title' }
        end

        it_behaves_like 'an endpoint with mcp route setting', :update_merge_request,
          expected_params: API::Helpers::MergeRequestsHelpers.update_merge_request_mcp_params, status: :ok
      end

      context 'when only assignee_ids are provided' do
        let(:params) do
          {
            assignee_ids: [user2.id]
          }
        end

        it 'sets the assignees' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['assignees']).to contain_exactly(
            a_hash_including('name' => user2.name)
          )
        end

        it 'creates appropriate system notes', :sidekiq_inline do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(merge_request.notes.system.last.note).to include("assigned to #{user2.to_reference}")
        end

        it 'triggers webhooks', :sidekiq_inline do
          hook = create(:project_hook, merge_requests_events: true, project: merge_request.project)

          expect(WebHookWorker).to receive(:perform_async).with(hook.id, anything, 'merge_request_hooks', anything)

          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
        end
      end

      context 'when assignee_id=user2.id' do
        let(:params) do
          {
            assignee_id: user2.id
          }
        end

        it 'sets the assignees' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['assignees']).to contain_exactly(
            a_hash_including('name' => user2.name)
          )
        end
      end

      context 'when assignee_id=0' do
        let(:params) do
          {
            assignee_id: 0
          }
        end

        it 'clears the assignees' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['assignees']).to be_empty
        end

        it 'creates appropriate system notes', :sidekiq_inline do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(merge_request.notes.system.last.note).to include("unassigned #{user.to_reference}")
        end
      end

      context 'when only assignee_ids are provided, and the list is empty' do
        let(:params) do
          {
            assignee_ids: []
          }
        end

        it 'clears the assignees' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['assignees']).to be_empty
        end
      end

      context 'when only assignee_ids are provided, and the list contains the sentinel value' do
        let(:params) do
          {
            assignee_ids: [0]
          }
        end

        it 'clears the assignees' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['assignees']).to be_empty
        end
      end

      context 'with reviewer_ids' do
        let(:params) do
          {
            title: 'Updated merge request',
            reviewer_ids: [user2.id]
          }
        end

        it 'adds a reviewer to the existing merge request' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['title']).to eq('Updated merge request')
          expect(json_response['reviewers'].first['name']).to eq(user2.name)
        end

        it 'removes a reviewer from the existing merge request' do
          merge_request.reviewers = [user2]
          params[:reviewer_ids] = []

          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['title']).to eq('Updated merge request')
          expect(json_response['reviewers']).to be_empty
        end
      end

      context 'with merge_after' do
        let(:params) { { merge_after: '2025-01-09T20:47+0100' } }

        it 'sets merge_after on the MR' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['merge_after']).to eq('2025-01-09T19:47:00.000Z')
        end

        context 'when the user is an assignee without permission to set merge request metadata' do
          let_it_be(:planner) { create(:user, planner_of: project) }

          before do
            merge_request.update!(assignees: [planner])
          end

          it 'ignores merge_after' do
            put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", planner),
              params: params.merge(title: 'Updated title')

            expect(response).to have_gitlab_http_status(:ok)
            expect(json_response['title']).to eq('Updated title')
            expect(json_response['merge_after']).to be_nil
          end
        end
      end

      context 'with oauth token that has ai_workflows scope' do
        let(:token) { create(:oauth_access_token, user: user, scopes: [:ai_workflows]) }

        it "allows access" do
          put api(
            "/projects/#{project.id}/merge_requests/#{merge_request.iid}?title=new_title",
            oauth_access_token: token
          )

          expect(response).to have_gitlab_http_status(:ok)
        end

        it "allows access to the project passed as a full path" do
          put api(
            "/projects/#{CGI.escape(project.full_path)}/merge_requests/#{merge_request.iid}?title=new_title",
            oauth_access_token: token
          )

          expect(response).to have_gitlab_http_status(:ok)
        end
      end

      context 'with composite identity', :request_store, :sidekiq_inline do
        let_it_be(:service_account) do
          create(:user, :service_account, composite_identity_enforced: true, developer_of: project)
        end

        context 'when human user assigns a service account as reviewer (web session)' do
          it 'attributes the system note to the human user' do
            put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
              params: { reviewer_ids: [service_account.id] }

            expect(response).to have_gitlab_http_status(:ok)
            expect(merge_request.notes.system.last.author).to eq(user)
          end
        end

        context 'when human user assigns a service account as assignee (web session)' do
          it 'attributes the system note to the human user' do
            put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
              params: { assignee_ids: [service_account.id] }

            expect(response).to have_gitlab_http_status(:ok)
            expect(merge_request.notes.system.last.author).to eq(user)
          end
        end

        context 'when service account acts via OAuth token (authentication context)' do
          before do
            ::Gitlab::Auth::Identity.new(service_account).link!(user, context: :authentication)
          end

          it 'attributes the system note to the service account' do
            put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", service_account),
              params: { title: 'Updated title' }

            expect(response).to have_gitlab_http_status(:ok)
            expect(merge_request.notes.system.last.author).to eq(service_account)
          end
        end
      end
    end

    context 'with remove_source_branch' do
      it 'sets to false' do
        merge_request.update!(merge_params: { 'force_remove_source_branch' => true })

        expect(merge_request.force_remove_source_branch?).to be_truthy

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
          params: { state_event: "close", remove_source_branch: false }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['state']).to eq('closed')
        expect(json_response['force_remove_source_branch']).to be_falsey
      end

      it 'sets to true' do
        merge_request.update!(merge_params: { 'force_remove_source_branch' => false })

        expect(merge_request.force_remove_source_branch?).to be false

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
          params: { state_event: "close", remove_source_branch: true }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['state']).to eq('closed')
        expect(json_response['force_remove_source_branch']).to be_truthy
      end

      context 'with a merge request across forks' do
        let(:project) do
          create(:project, :public, :repository, creator: user, namespace: user.namespace,
            only_allow_merge_if_pipeline_succeeds: false)
        end

        let(:fork_owner) { create(:user) }
        let(:source_project) { fork_project(project, fork_owner) }
        let(:target_project) { project }

        let(:merge_request) do
          create(
            :merge_request,
            source_project: source_project,
            target_project: target_project,
            source_branch: 'fixes',
            merge_params: { 'force_remove_source_branch' => false }
          )
        end

        it 'is true for an authorized user' do
          put api("/projects/#{target_project.id}/merge_requests/#{merge_request.iid}", fork_owner),
            params: { state_event: 'close', remove_source_branch: true }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['state']).to eq('closed')
          expect(json_response['force_remove_source_branch']).to be true
        end

        it 'is false for an unauthorized user' do
          expect do
            put api("/projects/#{target_project.id}/merge_requests/#{merge_request.iid}", target_project.first_owner),
              params: { state_event: 'close', remove_source_branch: true }
          end.not_to change { merge_request.reload.merge_params }

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['state']).to eq('closed')
          expect(json_response['force_remove_source_branch']).to be false
        end
      end
    end

    context "when reopening a merge request" do
      let(:merge_request) do
        create(:merge_request, :closed, author: user, assignees: [user], source_project: project,
          target_project: project, source_branch: 'markdown')
      end

      it "reopens the merge request" do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: { state_event: "reopen" }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['state']).to eq('opened')
      end

      context "when the source branch no longer exists" do
        let(:merge_request) do
          create(:merge_request, :closed, author: user, assignees: [user], source_project: project,
            target_project: project, source_branch: 'this-source-branch-does-not-exist')
        end

        let(:branch_error) do
          'Cannot reopen this merge request because the source or target branch no longer exists.'
        end

        it "does not reopen the merge request and returns an error" do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
            params: { state_event: "reopen" }

          expect(response).to have_gitlab_http_status(:unprocessable_entity)
          expect(json_response['message']).to include(branch_error)
        end

        it "does not apply other changes in the same request" do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
            params: { state_event: "reopen", title: "A brand new title" }

          expect(response).to have_gitlab_http_status(:unprocessable_entity)
          expect(merge_request.reload).to be_closed
          expect(merge_request.title).not_to eq("A brand new title")
        end
      end
    end

    it "updates title and returns merge_request" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: { title: "New title" }
      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['title']).to eq('New title')
    end

    it "updates description and returns merge_request" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { description: "New description" }
      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['description']).to eq('New description')
    end

    it "updates milestone_id and returns merge_request" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { milestone_id: milestone.id }
      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['milestone']['id']).to eq(milestone.id)
    end

    it "leaves the milestone unchanged when milestone_id is invalid" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { milestone_id: non_existing_record_id }

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['milestone']).to be_nil
    end

    it "updates milestone via title and returns merge_request" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { milestone: milestone.title }

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['milestone']['id']).to eq(milestone.id)
    end

    it "leaves the milestone unchanged when the milestone title does not match any milestone in scope" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { milestone: 'nonexistent' }

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['milestone']).to be_nil
    end

    it "returns 400 when both milestone and milestone_id are provided" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { milestone: milestone.title, milestone_id: milestone.id }

      expect(response).to have_gitlab_http_status(:bad_request)
    end

    it "returns 400 when milestone title exceeds the length limit" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { milestone: 'a' * 256 }

      expect(response).to have_gitlab_http_status(:bad_request)
      expect(json_response['error']).to include('milestone must be less than 255 characters')
    end

    it "updates squash and returns merge_request" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: { squash: true }

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['squash']).to be_truthy
    end

    it "updates target_branch and returns merge_request" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user), params: { target_branch: "wiki" }
      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['target_branch']).to eq('wiki')
    end

    it_behaves_like 'authorizing granular token permissions', :update_merge_request do
      let(:boundary_object) { project }
      let(:request) do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", personal_access_token: pat),
          params: { title: 'New title' }
      end
    end

    context "with forked projects" do
      let_it_be(:user2, freeze: false) { create(:user) }

      let(:project) { create(:project, :public, :repository) }
      let!(:forked_project) { fork_project(project, user2, repository: true) }
      let(:merge_request) do
        create(
          :merge_request,
          source_project: forked_project,
          target_project: project,
          source_branch: "fixes"
        )
      end

      shared_examples "update of allow_collaboration and allow_maintainer_to_push" do |request_value, expected_value|
        it "updates with either param to #{request_value} and returns #{expected_value} for `allow_collaboration`" do
          %w[allow_collaboration allow_maintainer_to_push].each do |attr|
            merge_request.update_column(:allow_maintainer_to_push, !request_value)

            put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user2),
              params: { attr => request_value }

            expect(response).to have_gitlab_http_status(:ok)
            expect(json_response["allow_collaboration"]).to eq(expected_value)
            expect(json_response["allow_maintainer_to_push"]).to eq(expected_value)
          end
        end
      end

      context "when source project is public (i.e. MergeRequest#collaborative_push_possible? == true)" do
        it_behaves_like "update of allow_collaboration and allow_maintainer_to_push", true, true
      end

      context "when source project is private (i.e. MergeRequest#collaborative_push_possible? == false)" do
        let(:project) { create(:project, :private, :repository, reporters: user2) }

        it_behaves_like "update of allow_collaboration and allow_maintainer_to_push", true, false
      end
    end

    context 'when updating labels' do
      it 'allows special label names' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
          params: {
            title: 'new issue',
            labels: 'label, label?, label&foo, ?, &'
          }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to include 'label'
        expect(json_response['labels']).to include 'label?'
        expect(json_response['labels']).to include 'label&foo'
        expect(json_response['labels']).to include '?'
        expect(json_response['labels']).to include '&'
      end

      it 'empty label param removes labels' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
          params: {
            title: 'new issue',
            labels: ''
          }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to eq []
      end

      it 'label param as empty array, but only explicitly as json, removes labels' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
          params: {
            title: 'new issue',
            labels: []
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to eq []
      end

      it 'empty label as array, removes labels' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
          params: {
            title: 'new issue',
            labels: []
          }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to eq []
      end

      it 'array with one empty string element removes labels' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
          params: {
            title: 'new issue',
            labels: ['']
          }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to eq []
      end

      it 'array with multiple empty string elements, removes labels' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
          params: {
            title: 'new issue',
            labels: ['', '', '']
          }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to eq []
      end
    end

    context 'with labels' do
      include_context 'with labels'

      let(:api_base) { api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user) }

      it 'when adding labels, keeps existing labels and adds new' do
        put api_base, params: { add_labels: '1, 2' }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to contain_exactly(label.title, label2.title, '1', '2')
      end

      it 'when removing labels, only removes those specified' do
        put api_base, params: { remove_labels: label.title.to_s }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to eq([label2.title])
      end

      it 'when removing all labels, keeps no labels' do
        put api_base, params: { remove_labels: "#{label.title}, #{label2.title}" }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['labels']).to be_empty
      end
    end

    it 'does not update state when title is empty' do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { state_event: 'close', title: nil }

      merge_request.reload
      expect(response).to have_gitlab_http_status(:bad_request)
      expect(merge_request.state).to eq('opened')
    end

    it 'does not update state when target_branch is empty' do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user),
        params: { state_event: 'close', target_branch: nil }

      merge_request.reload
      expect(response).to have_gitlab_http_status(:bad_request)
      expect(merge_request.state).to eq('opened')
    end

    it "returns 404 for an invalid merge request IID" do
      put api("/projects/#{project.id}/merge_requests/#{non_existing_record_iid}", user),
        params: { state_event: "close" }

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it "returns 404 if the merge request id is used instead of iid" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request_id_not_used_as_iid}", user),
        params: { state_event: "close" }

      expect(response).to have_gitlab_http_status(:not_found)
    end
  end

  describe "DELETE /projects/:id/merge_requests/:merge_request_iid" do
    include_context 'with a merge request created once'

    context "when the user is developer" do
      let(:developer) { create(:user) }

      before do
        project.add_developer(developer)
      end

      it "denies the deletion of the merge request" do
        delete api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", developer)
        expect(response).to have_gitlab_http_status(:forbidden)
      end
    end

    context "when the user is project owner" do
      it "returns 404 for an invalid merge request IID" do
        delete api("/projects/#{project.id}/merge_requests/#{non_existing_record_iid}", user)

        expect(response).to have_gitlab_http_status(:not_found)
      end

      it "returns 404 if the merge request id is used instead of iid" do
        delete api("/projects/#{project.id}/merge_requests/#{merge_request_id_not_used_as_iid}", user)

        expect(response).to have_gitlab_http_status(:not_found)
      end

      it_behaves_like '412 response' do
        let(:request) { api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", user) }
      end
    end

    it_behaves_like 'authorizing granular token permissions', :delete_merge_request do
      let(:boundary_object) { project }
      let(:request) do
        delete api("/projects/#{project.id}/merge_requests/#{merge_request.iid}", personal_access_token: pat)
      end
    end
  end

  shared_examples 'merging with auto merge strategies' do
    context 'when only_allow_merge_if_pipeline_succeeds is true' do
      before do
        project.update_attribute(:only_allow_merge_if_pipeline_succeeds, true)
      end

      it 'sets auto merge when the pipeline has failed' do
        create(:ci_pipeline,
          :failed,
          sha: merge_request.diff_head_sha,
          merge_requests_as_head_pipeline: [merge_request])

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['merge_when_pipeline_succeeds']).to be(true)
        expect(merge_request.reload.state).to eq('opened')
      end

      it "sets auto merge when the pipeline is active" do
        allow_next_found_instance_of(MergeRequest) do |merge_request|
          allow(merge_request).to receive_messages(head_pipeline: pipeline, diff_head_pipeline: pipeline)
        end
        allow(pipeline).to receive(:active?).and_return(true)

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['title']).to eq('Test')
        expect(json_response['merge_when_pipeline_succeeds']).to be(true)
      end

      it 'merges when the pipeline succeeds' do
        create(:ci_pipeline, :success, sha: merge_request.diff_head_sha,
          merge_requests_as_head_pipeline: [merge_request])

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['state']).to eq('merged')
      end

      it 'sets auto merge when no pipeline exists' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['merge_when_pipeline_succeeds']).to be(true)
        expect(merge_request.reload.state).to eq('opened')
      end

      it 'returns 422 when the pipeline succeeds but merge fails' do
        create(:ci_pipeline, :success, sha: merge_request.diff_head_sha,
          merge_requests_as_head_pipeline: [merge_request])

        allow_next_instance_of(AutoMergeService) do |service|
          allow(service).to receive(:available_strategies).and_return([])
        end

        allow_next_instance_of(::MergeRequests::MergeService) do |service|
          allow(service).to receive(:execute)
        end

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

        expect(response).to have_gitlab_http_status(:unprocessable_entity)
        expect(json_response['message']).to eq('Branch cannot be merged')
      end
    end

    context 'when only_allow_merge_if_pipeline_succeeds is false' do
      before do
        project.update_attribute(:only_allow_merge_if_pipeline_succeeds, false)
      end

      it "returns 422 if branch can't be merged due to mergeability check" do
        create(:ci_pipeline, :success, sha: merge_request.diff_head_sha,
          merge_requests_as_head_pipeline: [merge_request])

        allow_next_instance_of(AutoMergeService) do |service|
          allow(service).to receive(:available_strategies).and_return([])
        end

        allow_next_found_instance_of(MergeRequest) do |merge_request|
          allow(merge_request).to receive(:mergeable?).and_return(false)
        end

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

        expect(response).to have_gitlab_http_status(:unprocessable_entity)
        expect(json_response['message']).to eq('Branch cannot be merged')
      end

      it 'returns not allowed when the pipeline has failed' do
        create(:ci_pipeline,
          :failed,
          sha: merge_request.diff_head_sha,
          merge_requests_as_head_pipeline: [merge_request])

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

        expect(response).to have_gitlab_http_status(:method_not_allowed)
      end

      context 'when no pipeline exists' do
        it 'merges immediately' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['state']).to eq('merged')
        end
      end

      context 'when no pipeline exists but one is being created' do
        before do
          allow_next_found_instance_of(MergeRequest) do |mr|
            allow(mr).to receive(:pipeline_creating?).and_return(true)
          end
        end

        it 'sets auto merge' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

          expect(response).to have_gitlab_http_status(:ok)
          expect(json_response['merge_when_pipeline_succeeds']).to be(true)
          expect(merge_request.reload.state).to eq('opened')
        end
      end

      it "sets auto merge when the pipeline is active" do
        allow_next_found_instance_of(MergeRequest) do |merge_request|
          allow(merge_request).to receive_messages(head_pipeline: pipeline, diff_head_pipeline: pipeline)
        end
        allow(pipeline).to receive(:active?).and_return(true)

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: params

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['title']).to eq('Test')
        expect(json_response['state']).to eq('opened')
        expect(json_response['merge_when_pipeline_succeeds']).to be(true)
      end
    end
  end

  describe "PUT /projects/:id/merge_requests/:merge_request_iid/merge", :clean_gitlab_redis_cache do
    let(:project) { create(:project, :repository, namespace: user.namespace) }
    let(:merge_request) do
      create(:merge_request, :simple, author: user, source_project: project, source_branch: 'markdown', title: 'Test')
    end

    let(:pipeline) { create(:ci_pipeline, project: project) }

    context 'with oauth token that has ai_workflows scope' do
      let(:token) { create(:oauth_access_token, user: user, scopes: [:ai_workflows]) }

      it "does not allow access" do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", oauth_access_token: token)

        expect(response).to have_gitlab_http_status(:forbidden)
      end
    end

    it_behaves_like 'authorizing granular token permissions', :merge_merge_request do
      let(:boundary_object) { project }
      let(:request) do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", personal_access_token: pat)
      end
    end

    it "returns merge_request in case of success" do
      expect { put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user) }
        .to change { merge_request.reload.merged? }
        .from(false)
        .to(true)

      expect(response).to have_gitlab_http_status(:ok)
    end

    context 'when the merge request fails to merge' do
      it 'returns 422' do
        expect_next_instance_of(::MergeRequests::MergeService) do |service|
          expect(service).to receive(:execute)
        end

        expect { put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user) }
          .not_to change { merge_request.reload.merged? }

        expect(response).to have_gitlab_http_status(:unprocessable_entity)
        expect(json_response['message']).to eq("Branch cannot be merged")
      end
    end

    it "returns 405 if branch can't be merged" do
      allow_next_found_instance_of(MergeRequest) do |merge_request|
        allow(merge_request).to receive(:mergeable?).and_return(false)
      end

      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user)

      expect(response).to have_gitlab_http_status(:method_not_allowed)
      expect(json_response['message']).to eq('405 Method Not Allowed')
    end

    it 'returns 405 if the build failed for a merge request that requires success' do
      project.update!(only_allow_merge_if_pipeline_succeeds: true)

      create(
        :ci_pipeline,
        :failed,
        sha: merge_request.diff_head_sha,
        merge_requests_as_head_pipeline: [merge_request]
      )

      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user)

      expect(response).to have_gitlab_http_status(:method_not_allowed)
      expect(json_response['message']).to eq('405 Method Not Allowed')
    end

    it "returns 401 if user has no permissions to merge" do
      user2 = create(:user)
      project.add_reporter(user2)
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user2)
      expect(response).to have_gitlab_http_status(:unauthorized)
      expect(json_response['message']).to eq('401 Unauthorized')
    end

    it "returns 409 if the SHA parameter doesn't match" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
        params: { sha: merge_request.diff_head_sha.reverse }

      expect(response).to have_gitlab_http_status(:conflict)
      expect(json_response['message']).to start_with('SHA does not match HEAD of source branch')
    end

    shared_examples 'enforces presence of SHA parameter' do
      it 'returns 400 when sha param is not provided' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user)

        expect(response).to have_gitlab_http_status(:bad_request)
        expect(json_response['message']).to eq('SHA must be provided when merging')
      end

      it 'proceeds with merge when sha param is provided' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
          params: { sha: merge_request.diff_head_sha }

        expect(response).to have_gitlab_http_status(:ok)
      end
    end

    context 'when a namespace requires SHA for merge' do
      before do
        project.namespace.namespace_settings.update!(require_sha_for_merge: true)
      end

      it_behaves_like 'enforces presence of SHA parameter'
    end

    context 'when the new auto_merge param is used' do
      let(:params) { { auto_merge: true } }

      it_behaves_like 'merging with auto merge strategies'
    end

    context 'when the MR is still preparing and a pipeline is being created', :clean_gitlab_redis_shared_state do
      # Reproduces the transient state right after POST /merge_requests, where the MR is
      # preparing (diffs not computed) and a pipeline is being created.
      # See https://gitlab.com/gitlab-org/gitlab/-/work_items/473054
      before do
        merge_request.mark_as_preparing!
        Ci::PipelineCreation::Requests.start_for_merge_request(merge_request)
      end

      it 'sets auto merge instead of returning 405' do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
          params: { auto_merge: true }

        expect(response).to have_gitlab_http_status(:ok)
        expect(merge_request.reload.auto_merge_enabled).to be(true)
        expect(merge_request.auto_merge_strategy).to eq(AutoMergeService::STRATEGY_MERGE_WHEN_CHECKS_PASS)
      end
    end

    context 'when the MR is still preparing and its diff has not been created yet' do
      # Reproduces the window between POST /merge_requests returning and NewMergeRequestWorker
      # writing the diff. See https://gitlab.com/gitlab-org/cli/-/work_items/8140
      let(:merge_request) do
        create(:merge_request, :simple, :skip_diff_creation, author: user, source_project: project,
          source_branch: 'markdown', title: 'Test')
      end

      before do
        merge_request.mark_as_preparing!
      end

      it 'sets auto merge instead of returning 422' do
        expect(merge_request.has_no_commits?).to be(true)

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
          params: { auto_merge: true }

        expect(response).to have_gitlab_http_status(:ok)
        expect(merge_request.reload.auto_merge_enabled).to be(true)
        expect(merge_request.auto_merge_strategy).to eq(AutoMergeService::STRATEGY_MERGE_WHEN_CHECKS_PASS)
      end
    end

    it 'enables auto merge if the MR is not mergeable and only_allow_merge_if_pipeline_succeeds is true' do
      allow_next_found_instance_of(MergeRequest) do |merge_request|
        allow(merge_request).to receive_messages(head_pipeline: pipeline, diff_head_pipeline: pipeline)
      end

      merge_request.update!(title: 'Draft: 1234')

      project.update_attribute(:only_allow_merge_if_pipeline_succeeds, true)

      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
        params: { merge_when_pipeline_succeeds: true }

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['title']).to eq('Draft: 1234')
      expect(json_response['merge_when_pipeline_succeeds']).to be(true)
    end

    context 'when auto merge is already enabled' do
      before do
        create(:ci_pipeline, :running, sha: merge_request.diff_head_sha,
          merge_requests_as_head_pipeline: [merge_request])

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: { auto_merge: true }
      end

      it 'updates the merge params without processing auto merge again' do
        expect(AutoMergeProcessWorker).not_to receive(:perform_async)

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
          params: { auto_merge: true, merge_commit_message: 'Updated message' }

        expect(response).to have_gitlab_http_status(:ok)
        expect(merge_request.reload.merge_params['commit_message']).to eq('Updated message')
      end
    end

    context 'when the pipeline failed' do
      let(:pipeline) { create(:ci_pipeline, :failed, project: project) }

      it "enables auto merge if the pipeline is failed and only_allow_merge_if_pipeline_succeeds is true" do
        allow_next_found_instance_of(MergeRequest) do |merge_request|
          allow(merge_request).to receive_messages(head_pipeline: pipeline, diff_head_pipeline: pipeline)
        end
        project.update_attribute(:only_allow_merge_if_pipeline_succeeds, true)

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
          params: { merge_when_pipeline_succeeds: true }

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['title']).to eq('Test')
        expect(json_response['merge_when_pipeline_succeeds']).to be(true)
      end
    end

    it "returns 404 for an invalid merge request IID" do
      put api("/projects/#{project.id}/merge_requests/#{non_existing_record_iid}/merge", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it "returns 404 if the merge request id is used instead of iid" do
      put api("/projects/#{project.id}/merge_requests/#{merge_request_id_not_used_as_iid}/merge", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    describe "the squash_commit_message param" do
      let(:squash_commit) do
        project.repository.commits_between(json_response['diff_refs']['start_sha'],
          json_response['merge_commit_sha']).first
      end

      it "results in a specific squash commit message when set" do
        squash_commit_message = 'My custom squash commit message'

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: {
          squash: true,
          squash_commit_message: squash_commit_message
        }

        expect(response).to have_gitlab_http_status(:ok)
        expect(squash_commit.message.chomp).to eq(squash_commit_message)
      end

      it "results in a default squash commit message when not set" do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user), params: { squash: true }

        expect(response).to have_gitlab_http_status(:ok)
        expect(merge_request.reload.squash_on_merge?).to be(true)
        expect(squash_commit.message.chomp).to eq(merge_request.default_squash_commit_message.chomp)
      end

      context 'when squash_commit_message is empty' do
        it 'uses a default squash commit message' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
            params: { squash: true, squash_commit_message: '' }

          expect(response).to have_gitlab_http_status(:ok)
          expect(squash_commit.message.chomp).to eq(merge_request.default_squash_commit_message.chomp)
        end
      end

      context 'when a squash commit message was saved with auto-merge' do
        let(:saved_message) { 'Saved with auto-merge' }
        let(:merge_path) { api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user) }
        let(:committed_squash_message) do
          project.commit(merge_request.reload.squash_commit_sha).message.chomp
        end

        let!(:pipeline) do
          create(:ci_pipeline, :running, project: project, sha: merge_request.diff_head_sha,
            merge_requests_as_head_pipeline: [merge_request])
        end

        before do
          project.update!(only_allow_merge_if_pipeline_succeeds: true)

          put merge_path, params: { auto_merge: true, squash: true, squash_commit_message: saved_message }
        end

        it 'saves the message and rejects an immediate merge while the pipeline is running' do
          expect(merge_request.reload.merge_params['squash_commit_message']).to eq(saved_message)

          put merge_path

          expect(response).to have_gitlab_http_status(:method_not_allowed)
          expect(merge_request.reload).to be_opened
          expect(merge_request.auto_merge_enabled).to be(true)
        end

        context 'when the pipeline succeeds before auto-merge is processed' do
          before do
            pipeline.succeed!
          end

          it 'commits the default message when the request sends none' do
            put merge_path

            expect(response).to have_gitlab_http_status(:ok)
            expect(committed_squash_message).to eq(merge_request.default_squash_commit_message.chomp)
          end

          it 'commits the message from the request' do
            put merge_path, params: { squash_commit_message: 'Sent with the merge request' }

            expect(response).to have_gitlab_http_status(:ok)
            expect(committed_squash_message).to eq('Sent with the merge request')
          end
        end
      end
    end

    describe "the should_remove_source_branch param", :sidekiq_inline do
      let(:source_repository) { merge_request.source_project.repository }
      let(:source_branch) { merge_request.source_branch }

      it 'removes the source branch when set' do
        put(
          api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
          params: { should_remove_source_branch: true }
        )

        expect(response).to have_gitlab_http_status(:ok)
        expect(source_repository.branch_exists?(source_branch)).to be false
        expect(merge_request.reload.should_remove_source_branch?).to be true
      end
    end

    context "with a merge request that has force_remove_source_branch enabled", :sidekiq_inline do
      let(:source_repository) { merge_request.source_project.repository }
      let(:source_branch) { merge_request.source_branch }

      before do
        merge_request.update!(merge_params: { 'force_remove_source_branch' => true })
      end

      it 'removes the source branch' do
        put(
          api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user)
        )

        expect(response).to have_gitlab_http_status(:ok)
        expect(source_repository.branch_exists?(source_branch)).to be false
        expect(merge_request.reload.should_remove_source_branch?).to be_nil
      end

      it 'does not remove the source branch' do
        put(
          api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user),
          params: { should_remove_source_branch: false }
        )

        expect(response).to have_gitlab_http_status(:ok)
        expect(source_repository.branch_exists?(source_branch)).to be_truthy
        expect(merge_request.reload.should_remove_source_branch?).to be false
      end
    end

    context "when performing a fast-forward merge with squash" do
      let(:merge_request) { create(:merge_request, :rebased, source_project: project, squash: true) }

      before do
        project.update!(merge_requests_ff_only_enabled: true)
      end

      it "records the squash commit SHA and returns it in the response" do
        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge", user)

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['squash_commit_sha'].length).to eq(40)
      end
    end
  end

  describe "GET /projects/:id/merge_requests/:merge_request_iid/merge_ref", :clean_gitlab_redis_shared_state do
    before do
      merge_request.mark_as_unchecked!
    end

    let(:merge_request_iid) { merge_request.iid }

    let(:url) do
      "/projects/#{project.id}/merge_requests/#{merge_request_iid}/merge_ref"
    end

    it 'returns the generated ID from the merge service in case of success' do
      get api(url, user)

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['commit_id']).to eq(merge_request.merge_ref_head.sha)
    end

    context 'when merge-ref is not synced with merge status' do
      let_it_be_with_reload(:merge_request) do
        create(:merge_request, :simple, author: user, source_project: project, source_branch: 'markdown',
          merge_status: 'cannot_be_merged')
      end

      it 'returns 200 if MR can be merged' do
        get api(url, user)

        expect(response).to have_gitlab_http_status(:ok)
        expect(json_response['commit_id']).to eq(merge_request.merge_ref_head.sha)
      end

      it 'returns 400 if MR cannot be merged' do
        expect_next_instance_of(MergeRequests::MergeToRefService) do |merge_request|
          expect(merge_request).to receive(:execute).and_return({ status: :failed })
        end

        get api(url, user)

        expect(response).to have_gitlab_http_status(:bad_request)
        expect(json_response['message']).to eq('Merge request is not mergeable')
      end
    end

    context 'when user has no access to the MR' do
      let(:project) { create(:project, :private) }
      let(:merge_request) { create(:merge_request, source_project: project, target_project: project) }

      it 'returns 404' do
        project.add_guest(user)

        get api(url, user)

        expect(response).to have_gitlab_http_status(:not_found)
        expect(json_response['message']).to eq('404 Not found')
      end
    end

    context 'when invalid merge request IID' do
      let(:merge_request_iid) { non_existing_record_iid }

      it 'returns 404' do
        get api(url, user)

        expect(response).to have_gitlab_http_status(:not_found)
      end
    end

    context 'when merge request ID is used instead IID' do
      let(:merge_request_iid) { merge_request_id_not_used_as_iid }

      it 'returns 404' do
        get api(url, user)

        expect(response).to have_gitlab_http_status(:not_found)
      end
    end

    context 'with the merge ref rate limit', :clean_gitlab_redis_rate_limiting do
      before do
        stub_application_setting(merge_requests_merge_ref_limit: 1)
      end

      it 'rate limits each user before the mergeability check', :aggregate_failures do
        expect(MergeRequests::MergeabilityCheckService).to receive(:new).twice.and_call_original

        get api(url, user)

        expect(response).to have_gitlab_http_status(:ok)

        get api(url, user)

        expect(response).to have_gitlab_http_status(:too_many_requests)
        expect(response.headers['RateLimit-Name']).to eq('merge_requests_merge_ref')

        get api(url, user2)

        expect(response).to have_gitlab_http_status(:ok)
      end

      it 'rate limits an anonymous request by IP address' do
        get api(url)
        get api(url)

        expect(response).to have_gitlab_http_status(:too_many_requests)
      end
    end

    it_behaves_like 'authorizing granular token permissions', :read_merge_request_merge_ref do
      let(:boundary_object) { project }
      let(:request) do
        get api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/merge_ref", personal_access_token: pat)
      end
    end
  end

  describe 'POST :id/merge_requests/:merge_request_iid/subscribe' do
    include_context 'with a merge request created once'

    it_behaves_like 'POST request permissions for admin mode' do
      let(:path) { "/projects/#{project.id}/merge_requests/#{merge_request.iid}/subscribe" }
      let(:params) { {} }
    end

    it_behaves_like 'authorizing granular token permissions', :subscribe_merge_request,
      expected_success_status: :not_modified do
      let(:boundary_object) { project }
      let(:request) do
        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/subscribe", personal_access_token: pat)
      end
    end

    it 'subscribes to a merge request' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/subscribe", admin, admin_mode: true)

      expect(response).to have_gitlab_http_status(:created)
      expect(json_response['subscribed']).to be(true)
    end

    it 'returns 304 if already subscribed' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/subscribe", user)

      expect(response).to have_gitlab_http_status(:not_modified)
    end

    it 'returns 404 if the merge request is not found' do
      post api("/projects/#{project.id}/merge_requests/#{non_existing_record_iid}/subscribe", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'returns 404 if the merge request id is used instead of iid' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request_id_not_used_as_iid}/subscribe", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'returns 403 if user has no access to read code' do
      guest = create(:user)
      project.add_guest(guest)

      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/subscribe", guest)

      expect(response).to have_gitlab_http_status(:forbidden)
    end
  end

  describe 'POST :id/merge_requests/:merge_request_iid/unsubscribe' do
    include_context 'with a merge request created once'

    it_behaves_like 'authorizing granular token permissions', :subscribe_merge_request do
      let(:boundary_object) { project }
      let(:request) do
        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/unsubscribe", personal_access_token: pat)
      end
    end

    it 'unsubscribes from a merge request' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/unsubscribe", user)

      expect(response).to have_gitlab_http_status(:created)
      expect(json_response['subscribed']).to be(false)
    end

    it 'returns 304 if not subscribed' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/unsubscribe", admin, admin_mode: true)

      expect(response).to have_gitlab_http_status(:not_modified)
    end

    it 'returns 404 if the merge request is not found' do
      post api("/projects/#{project.id}/merge_requests/#{non_existing_record_iid}/unsubscribe", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'returns 404 if the merge request id is used instead of iid' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request_id_not_used_as_iid}/unsubscribe", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'returns 403 if user has no access to read code' do
      guest = create(:user)
      project.add_guest(guest)

      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/unsubscribe", guest)

      expect(response).to have_gitlab_http_status(:forbidden)
    end
  end

  describe 'POST :id/merge_requests/:merge_request_iid/cancel_merge_when_pipeline_succeeds' do
    context 'when an auto-merge is set' do
      let(:merge_request) do
        create(:merge_request, :simple, :merge_when_checks_pass, author: user, assignees: [user],
          source_project: project, target_project: project, source_branch: 'markdown', title: 'Test')
      end

      it 'answers 201 with a success status and cancels the auto-merge' do
        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_merge_when_pipeline_succeeds",
          user)

        expect(response).to have_gitlab_http_status(:created)
        expect(json_response).to eq('status' => 'success')
        expect(merge_request.reload.auto_merge_enabled).to be(false)
      end
    end

    context 'when no auto-merge is set' do
      it 'answers 201 with an error status, not 406' do
        merge_request.update!(auto_merge_enabled: false)

        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_merge_when_pipeline_succeeds",
          user)

        expect(response).to have_gitlab_http_status(:created)
        expect(json_response).to eq(
          'message' => "Can't cancel the automatic merge",
          'status' => 'error',
          'http_status' => 406
        )
      end
    end

    it 'returns 404 if the merge request is not found' do
      post api(
        "/projects/#{project.id}/merge_requests/#{non_existing_record_iid}/cancel_merge_when_pipeline_succeeds", user
      )

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'returns 404 if the merge request id is used instead of iid' do
      # A merge request in another project takes an id first, so this one's id
      # cannot also be its iid, whatever ran before this example.
      create(:merge_request)

      post api("/projects/#{project.id}/merge_requests/#{merge_request.id}/cancel_merge_when_pipeline_succeeds", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    context 'with oauth token that has ai_workflows scope' do
      let(:token) { create(:oauth_access_token, user: user, scopes: [:ai_workflows]) }

      it "does not allow access" do
        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_merge_when_pipeline_succeeds",
          oauth_access_token: token)

        expect(response).to have_gitlab_http_status(:forbidden)
      end
    end

    it_behaves_like 'authorizing granular token permissions', :cancel_merge_merge_request do
      let(:boundary_object) { project }
      let(:request) do
        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_merge_when_pipeline_succeeds",
          personal_access_token: pat)
      end
    end
  end

  describe 'POST :id/merge_requests/:merge_request_iid/cancel_auto_merge' do
    let(:merge_request) do
      create(:merge_request, :simple, :merge_when_checks_pass, author: user, assignees: [user],
        source_project: project, target_project: project, source_branch: 'markdown', title: "Test")
    end

    it 'removes the merge_when_pipeline_succeeds status and returns the merge request' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_auto_merge", user)

      expect(response).to have_gitlab_http_status(:created)
      expect(response).to match_response_schema('public_api/v4/merge_request')
      expect(json_response['id']).to eq(merge_request.id)
      expect(json_response['iid']).to eq(merge_request.iid)
      expect(json_response['merge_when_pipeline_succeeds']).to be(false)
      expect(merge_request.reload.auto_merge_enabled).to be(false)
    end

    it 'returns 409 if there is no automatic merge to cancel' do
      merge_request.update!(auto_merge_enabled: false)

      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_auto_merge", user)

      expect(response).to have_gitlab_http_status(:conflict)
      expect(json_response['message']).to eq("Can't cancel the automatic merge")
    end

    it 'returns 403 if the user cannot cancel the automatic merge' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_auto_merge", user2)

      expect(response).to have_gitlab_http_status(:forbidden)
      expect(json_response['message']).to eq('403 Forbidden')
      expect(merge_request.reload.auto_merge_enabled).to be(true)
    end

    context 'when the author cannot merge the merge request' do
      let(:merge_request) do
        create(:merge_request, :simple, :merge_when_checks_pass, author: user2,
          source_project: project, target_project: project, source_branch: 'markdown', title: "Test")
      end

      it 'cancels the automatic merge and returns the merge request' do
        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_auto_merge", user2)

        expect(response).to have_gitlab_http_status(:created)
        expect(json_response['iid']).to eq(merge_request.iid)
        expect(json_response['merge_when_pipeline_succeeds']).to be(false)
        expect(merge_request.reload.auto_merge_enabled).to be(false)
      end
    end

    it 'returns 404 if the merge request is not found' do
      post api("/projects/#{project.id}/merge_requests/#{non_existing_record_iid}/cancel_auto_merge", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    it 'returns 404 if the merge request id is used instead of iid' do
      post api("/projects/#{project.id}/merge_requests/#{merge_request_id_not_used_as_iid}/cancel_auto_merge", user)

      expect(response).to have_gitlab_http_status(:not_found)
    end

    context 'with oauth token that has ai_workflows scope' do
      let(:token) { create(:oauth_access_token, user: user, scopes: [:ai_workflows]) }

      it "does not allow access" do
        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_auto_merge",
          oauth_access_token: token)

        expect(response).to have_gitlab_http_status(:forbidden)
      end
    end

    it_behaves_like 'authorizing granular token permissions', :cancel_merge_merge_request do
      let(:boundary_object) { project }
      let(:request) do
        post api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/cancel_auto_merge",
          personal_access_token: pat)
      end
    end
  end

  describe 'PUT :id/merge_requests/:merge_request_iid/rebase' do
    include_context 'with a merge request created once'

    context 'with oauth token that has ai_workflows scope' do
      let(:token) { create(:oauth_access_token, user: user, scopes: [:ai_workflows]) }

      it 'enqueues a rebase of the merge request' do
        Sidekiq::Testing.fake! do
          expect do
            put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", oauth_access_token: token)
          end.to change { RebaseWorker.jobs.size }.by(1)
        end

        expect(response).to have_gitlab_http_status(:accepted)
        expect(json_response['rebase_in_progress']).to be(true)
      end

      it 'allows access to the project passed as a full path' do
        Sidekiq::Testing.fake! do
          put api("/projects/#{CGI.escape(project.full_path)}/merge_requests/#{merge_request.iid}/rebase",
            oauth_access_token: token)
        end

        expect(response).to have_gitlab_http_status(:accepted)
      end

      context 'when the user cannot push to the branch' do
        let(:guest) { create(:user, guest_of: project) }
        let(:token) { create(:oauth_access_token, user: guest, scopes: [:ai_workflows]) }

        it 'returns 403' do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", oauth_access_token: token)

          expect(response).to have_gitlab_http_status(:forbidden)
          expect(json_response['message']).to eq('403 Forbidden - Cannot push to source branch')
        end
      end

      context 'with a composite identity token' do
        let(:service_account) { create(:user, :service_account, composite_identity_enforced: true) }
        let(:human_user) { create(:user) }
        let(:token) do
          create(:oauth_access_token, user: service_account, scopes: [:ai_workflows, :"user:#{human_user.id}"])
        end

        let(:rebase_request) do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", oauth_access_token: token)
        end

        context 'when both identities can push to the branch' do
          before do
            project.add_developer(service_account)
            project.add_developer(human_user)
          end

          it 'enqueues a rebase of the merge request' do
            Sidekiq::Testing.fake! do
              expect { rebase_request }.to change { RebaseWorker.jobs.size }.by(1)
            end

            expect(response).to have_gitlab_http_status(:accepted)
          end
        end

        context 'when the service account cannot push to the branch' do
          before do
            project.add_guest(service_account)
            project.add_developer(human_user)
          end

          it 'returns 403' do
            rebase_request

            expect(response).to have_gitlab_http_status(:forbidden)
            expect(json_response['message']).to eq('403 Forbidden - Cannot push to source branch')
          end
        end

        context 'when the human user cannot push to the branch' do
          before do
            project.add_developer(service_account)
            project.add_guest(human_user)
          end

          it 'returns 403' do
            rebase_request

            expect(response).to have_gitlab_http_status(:forbidden)
            expect(json_response['message']).to eq('403 Forbidden - Cannot push to source branch')
          end
        end
      end
    end

    context 'when rebase can be performed' do
      context 'when skip_ci parameter is set' do
        it 'enqueues a rebase of the merge request with skip_ci flag set' do
          with_status = RebaseWorker.with_status

          expect(RebaseWorker).to receive(:with_status).and_return(with_status)
          expect(with_status).to receive(:perform_async).with(merge_request.id, user.id, true).and_call_original

          Sidekiq::Testing.fake! do
            expect do
              put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", user),
                params: { skip_ci: true }
            end.to change { RebaseWorker.jobs.size }.by(1)
          end

          expect(response).to have_gitlab_http_status(:accepted)
          expect(merge_request.reload).to be_rebase_in_progress
          expect(json_response['rebase_in_progress']).to be(true)
        end
      end

      it_behaves_like 'authorizing granular token permissions', :rebase_merge_request do
        let(:boundary_object) { project }
        let(:request) do
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", personal_access_token: pat)
        end
      end

      it_behaves_like 'rate limited endpoint', rate_limit_key: :merge_requests_rebase, use_second_scope: false do
        let(:current_user) { user }

        def request
          put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", user)
        end
      end

      context 'when merge_requests_rebase_rate_limit is disabled' do
        before do
          stub_feature_flags(merge_requests_rebase_rate_limit: false)
        end

        it_behaves_like 'unthrottled endpoint', rate_limit_key: :merge_requests_rebase do
          def request
            put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", user)
          end
        end
      end
    end

    it 'does not check the rate limit if the user cannot push to the branch' do
      guest = create(:user, guest_of: project)

      expect(Gitlab::ApplicationRateLimiter).not_to receive(:throttled_request?)
        .with(anything, anything, :merge_requests_rebase, any_args)

      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", guest)

      expect(response).to have_gitlab_http_status(:forbidden)
    end

    it 'returns 409 if a rebase is already in progress' do
      Sidekiq::Testing.fake! do
        merge_request.rebase_async(user.id)

        put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", user)
      end

      expect(response).to have_gitlab_http_status(:conflict)
    end

    it "returns 409 if rebase can't lock the row" do
      allow_next_found_instance_of(MergeRequest) do |merge_request|
        allow(merge_request).to receive(:with_lock).and_raise(ActiveRecord::LockWaitTimeout)
      end
      expect(RebaseWorker).not_to receive(:perform_async)

      put api("/projects/#{project.id}/merge_requests/#{merge_request.iid}/rebase", user)

      expect(response).to have_gitlab_http_status(:conflict)
      expect(json_response['message']).to eq(
        'Failed to enqueue the rebase operation, possibly due to a long-lived transaction. Try again later.'
      )
    end
  end

  describe 'Time tracking' do
    let_it_be_with_refind(:issuable) do
      create(:merge_request, :simple, author: user, assignees: [user], source_project: project, target_project: project,
        source_branch: 'markdown', title: "Test", created_at: base_time)
    end

    include_examples 'time tracking endpoints', 'merge_request'
  end

  describe 'MCP tool input schemas', feature_category: :mcp_server do
    it 'locks the full input schema of get_merge_request_commits' do
      expect(Mcp::Tools::Manager.new.get_tool(name: 'get_merge_request_commits').input_schema).to eq({
        type: 'object',
        properties: {
          'id' => {
            type: 'string',
            description: 'ID or URL-encoded path of the project.'
          },
          'merge_request_iid' => {
            type: 'integer',
            description: 'Internal ID of the merge request.'
          },
          'per_page' => {
            type: 'integer',
            description: 'Number of items to list per page.'
          },
          'page' => {
            type: 'integer',
            description: 'Page number of results to retrieve.'
          }
        },
        required: %w[id merge_request_iid],
        additionalProperties: false
      })
    end

    it 'locks the full input schema of get_merge_request_diffs' do
      expect(Mcp::Tools::Manager.new.get_tool(name: 'get_merge_request_diffs').input_schema).to eq({
        type: 'object',
        properties: {
          'id' => {
            type: 'string',
            description: 'ID or URL-encoded path of the project.'
          },
          'merge_request_iid' => {
            type: 'integer',
            description: 'Internal ID of the merge request.'
          },
          'per_page' => {
            type: 'integer',
            description: 'Number of items to list per page.'
          },
          'page' => {
            type: 'integer',
            description: 'Page number of results to retrieve.'
          }
        },
        required: %w[id merge_request_iid],
        additionalProperties: false
      })
    end

    it 'locks the full input schema of get_merge_request_pipelines' do
      expect(Mcp::Tools::Manager.new.get_tool(name: 'get_merge_request_pipelines').input_schema).to eq({
        type: 'object',
        properties: {
          'id' => {
            type: 'string',
            description: 'ID or URL-encoded path of the project.'
          },
          'merge_request_iid' => {
            type: 'integer',
            description: 'Internal ID of the merge request.'
          }
        },
        required: %w[id merge_request_iid],
        additionalProperties: false
      })
    end
  end
end
