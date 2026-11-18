# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::CollaborativeEditing::DocumentStore, :clean_gitlab_redis_shared_state,
  feature_category: :wiki do
  let(:document_key) { 'wiki:Project:1:home' }

  subject(:store) { described_class.new(document_key) }

  describe '#updates' do
    it 'is empty for an unknown document' do
      expect(store.updates).to eq([])
    end

    it 'returns appended updates in order' do
      store.append('first')
      store.append('second')

      expect(store.updates).to eq(%w[first second])
    end
  end

  describe '#append' do
    it 'sets an expiry so documents do not accumulate once editing stops' do
      store.append('update')

      ttl = Gitlab::Redis::SharedState.with { |redis| redis.ttl(updates_key) }

      expect(ttl).to be_positive
    end

    it 'refreshes the expiry on every write' do
      store.append('update')
      Gitlab::Redis::SharedState.with { |redis| redis.expire(updates_key, 5) }

      store.append('another update')

      ttl = Gitlab::Redis::SharedState.with { |redis| redis.ttl(updates_key) }

      expect(ttl).to be > 5
    end

    it 'expires the byte counter with the document', :aggregate_failures do
      store.append('update')

      expect(ttl_of(bytes_key)).to be_positive
      expiries = Gitlab::Redis::SharedState.with do |redis|
        redis.multi do |transaction|
          transaction.pexpiretime(updates_key)
          transaction.pexpiretime(bytes_key)
        end
      end

      expect(expiries.uniq.size).to eq(1)
      expect(ttl_of("collaborative_editing:{#{document_key}}:snapshot_bytes")).to eq(-2)
    end

    context 'when the byte budget is reached' do
      before do
        stub_const("#{described_class}::MAX_LOG_BYTES", 10)
        stub_const("#{described_class}::COMPACTION_BYTES", 5)
      end

      it 'requests compaction before exhausting the budget' do
        expect(store.append('12345')).to be_compact
      end

      it 'does not compact a large snapshot after each update', :aggregate_failures do
        stub_const("#{described_class}::MAX_LOG_BYTES", 100)
        stub_const("#{described_class}::COMPACTION_BYTES", 50)
        token = store.append('a' * 50).compaction_token
        store.replace('a' * 60, token)

        5.times { expect(store.append('b')).not_to be_compact }
      end

      it 'requests compaction once the log doubles its snapshot size', :aggregate_failures do
        stub_const("#{described_class}::MAX_LOG_BYTES", 100)
        stub_const("#{described_class}::COMPACTION_BYTES", 50)
        token = store.append('a' * 50).compaction_token
        store.replace('a' * 30, token)

        expect(store.append('b' * 29)).not_to be_compact
        expect(store.append('b')).to be_compact
      end

      it 'compacts large snapshots halfway through the remaining budget', :aggregate_failures do
        stub_const("#{described_class}::MAX_LOG_BYTES", 100)
        stub_const("#{described_class}::COMPACTION_BYTES", 50)
        token = store.append('a' * 50).compaction_token
        store.replace('a' * 60, token)

        expect(store.append('b' * 19)).not_to be_compact
        result = store.append('b')

        expect(result).not_to be_full
        expect(result).to be_compact
      end

      it 'does not compact repeatedly after replacing a large snapshot', :aggregate_failures do
        stub_const("#{described_class}::MAX_LOG_BYTES", 100)
        stub_const("#{described_class}::COMPACTION_BYTES", 50)
        token = store.append('a' * 50).compaction_token
        store.replace('a' * 80, token)
        token = store.append('b' * 10).compaction_token

        expect(token).to be_present
        expect(store.replace('a' * 85, token)).to eq(:replaced)
        expect(store.append('b')).not_to be_compact
      end

      it 'still compacts a full log when the snapshot fills the budget', :aggregate_failures do
        token = store.append('12345').compaction_token
        store.replace('1234567890', token)

        result = store.append('1')

        expect(result).to be_full
        expect(result).to be_compact
      end

      it 'uses the compaction floor for small snapshots', :aggregate_failures do
        token = store.append('12345').compaction_token
        store.replace('1', token)

        expect(store.append('234')).not_to be_compact
        expect(store.append('5')).to be_compact
      end

      it 'counts the suffix towards growth since the last snapshot', :aggregate_failures do
        stub_const("#{described_class}::MAX_LOG_BYTES", 100)
        stub_const("#{described_class}::COMPACTION_BYTES", 50)
        token = store.append('a' * 50).compaction_token
        store.append('b' * 20)
        store.replace('a' * 30, token)

        expect(store.append('c' * 9)).not_to be_compact
        expect(store.append('c')).to be_compact
      end

      it 'rejects an update that would exceed the budget', :aggregate_failures do
        store.append('12345678')

        expect(store.append('123')).to be_full
        expect(store.updates).to eq(['12345678'])
      end

      it 'allows a compacted document to accept further updates', :aggregate_failures do
        token = store.append('12345678').compaction_token

        expect(store.replace('1234', token)).to eq(:replaced)
        expect(store.append('123456')).not_to be_full
        expect(store.updates).to eq(%w[1234 123456])
      end

      it 'rejects an over-budget snapshot without preventing a valid retry', :aggregate_failures do
        token = store.append('12345678').compaction_token

        expect(store.replace('12345678901', token)).to eq(:full)
        expect(store.updates).to eq(['12345678'])
        expect(store.append('123')).to be_full
        expect(store.append('1')).not_to be_full
        expect(store.replace('small', token)).to eq(:replaced)
        expect(store.updates).to eq(%w[small 1])
      end

      it 'includes updates added after the compaction claim in the byte budget', :aggregate_failures do
        token = store.append('12345').compaction_token
        store.append('1234')

        expect(store.replace('1234567', token)).to eq(:full)
        expect(store.updates).to eq(%w[12345 1234])
      end

      it 'keeps the accepted budget, baseline and expiries on a failed compaction', :aggregate_failures do
        stub_const("#{described_class}::COMPACTION_THRESHOLD", 2)
        token = store.append('12345').compaction_token
        store.replace('1234', token)
        token = store.append('1').compaction_token
        store.append('234')
        baseline_key = "collaborative_editing:{#{document_key}}:snapshot_bytes"
        claim_key = "collaborative_editing:{#{document_key}}:compaction"
        keys = [updates_key, bytes_key, baseline_key, claim_key]
        Gitlab::Redis::SharedState.with { |redis| keys.each { |key| redis.expire(key, 10) } }

        expect(store.replace('12345678', token)).to eq(:full)

        expect(store.updates).to eq(%w[1234 1 234])
        expect(Gitlab::Redis::SharedState.with { |redis| redis.mget(bytes_key, baseline_key) }).to eq(%w[8 4])
        keys.each { |key| expect(ttl_of(key)).to be_between(1, 10) }
      end

      it 'accepts a snapshot and suffix at the exact byte budget', :aggregate_failures do
        token = store.append('12345').compaction_token
        store.append('1234')

        expect(store.replace('123456', token)).to eq(:replaced)
        expect(store.updates).to eq(%w[123456 1234])
        expect(store.append('x')).to be_full
      end

      it 'lets another compactor recover a full log after a rejected claim expires', :aggregate_failures do
        token = store.append('12345').compaction_token
        store.append('67890')
        expect(store.replace('12345678', token)).to eq(:full)
        expect(store.append('x')).not_to be_compact
        expire_compaction_claim
        other_store = described_class.new(document_key)
        result = other_store.append('x')

        expect(result).to be_full
        expect(result).to be_compact
        expect(other_store.replace('small', token)).to eq(:invalid_claim)
        expect(other_store.replace('small', result.compaction_token)).to eq(:replaced)
        expect(store.append('x')).not_to be_full
        expect(store.updates).to eq(%w[small x])
      end
    end

    it 'refuses an update that is not a String' do
      expect { store.append(%w[a b]) }.to raise_error(ArgumentError)
    end

    it 'asks for no compaction while below the threshold', :aggregate_failures do
      result = store.append('update')

      expect(result).not_to be_full
      expect(result).not_to be_compact
    end

    it 'asks for compaction once the log reaches the threshold', :aggregate_failures do
      stub_const("#{described_class}::COMPACTION_THRESHOLD", 2)

      expect(store.append('first')).not_to be_compact
      expect(store.append('second')).to be_compact
    end

    it 'asks one caller only while the log stays uncompacted', :aggregate_failures do
      stub_const("#{described_class}::COMPACTION_THRESHOLD", 2)

      store.append('first')

      expect(store.append('second')).to be_compact
      expect(store.append('third')).not_to be_compact
      expect(store.append('fourth')).not_to be_compact
    end

    it 'asks again once the log has been compacted' do
      stub_const("#{described_class}::COMPACTION_THRESHOLD", 2)

      store.append('first')
      token = store.append('second').compaction_token

      store.replace('snapshot', token)

      expect(store.append('third')).to be_compact
    end

    it 'scopes the compaction claim to a single document' do
      stub_const("#{described_class}::COMPACTION_THRESHOLD", 1)

      store.append('first')

      expect(described_class.new('wiki:Project:1:other').append('first')).to be_compact
    end

    context 'when the log is at its ceiling' do
      before do
        stub_const("#{described_class}::COMPACTION_THRESHOLD", 2)
        stub_const("#{described_class}::MAX_LOG_LENGTH", 2)
      end

      it 'reports the document as full' do
        store.append('first')
        store.append('second')

        expect(store.append('third')).to be_full
      end

      it 'does not store the rejected update' do
        store.append('first')
        store.append('second')

        store.append('third')

        expect(store.updates).to eq(%w[first second])
      end

      it 'does not extend the life of a log it is refusing to write to' do
        store.append('first')
        store.append('second')
        Gitlab::Redis::SharedState.with { |redis| redis.expire(updates_key, 60) }

        store.append('third')

        ttl = Gitlab::Redis::SharedState.with { |redis| redis.ttl(updates_key) }

        expect(ttl).to be <= 60
      end

      it 'accepts updates again once the log has been compacted', :aggregate_failures do
        store.append('first')
        token = store.append('second').compaction_token

        store.replace('snapshot', token)

        expect(store.append('third')).not_to be_full
        expect(store.updates).to eq(%w[snapshot third])
      end

      context 'and the compactor never delivered a snapshot' do
        it 'asks a later caller to compact', :aggregate_failures do
          store.append('first')
          store.append('second')
          expire_compaction_claim

          result = store.append('third')

          expect(result).to be_full
          expect(result).to be_compact
        end

        it 'recovers the document when that caller compacts', :aggregate_failures do
          store.append('first')
          store.append('second')
          expire_compaction_claim

          token = store.append('third').compaction_token
          expect(store.replace('snapshot', token)).to eq(:replaced)

          expect(store.append('fourth')).not_to be_full
          expect(store.updates).to eq(%w[snapshot fourth])
        end

        it 'still asks only one caller at a time', :aggregate_failures do
          store.append('first')
          store.append('second')
          expire_compaction_claim

          expect(store.append('third')).to be_compact
          expect(store.append('fourth')).not_to be_compact
        end
      end
    end
  end

  describe '#replace' do
    let(:token) do
      stub_const("#{described_class}::COMPACTION_THRESHOLD", 2)

      store.append('first')
      store.append('second').compaction_token
    end

    it 'swaps the claimed log for the snapshot' do
      store.replace('snapshot', token)

      expect(store.updates).to eq(['snapshot'])
    end

    it 'sets an expiry on the compacted log' do
      store.replace('snapshot', token)

      ttl = Gitlab::Redis::SharedState.with { |redis| redis.ttl(updates_key) }

      expect(ttl).to be_positive
    end

    it 'refreshes the snapshot baseline expiry with the log', :aggregate_failures do
      store.replace('snapshot', token)
      key = "collaborative_editing:{#{document_key}}:snapshot_bytes"

      expect(ttl_of(key)).to be_positive
      Gitlab::Redis::SharedState.with { |redis| redis.expire(key, 5) }

      store.append('third')

      expect(ttl_of(key)).to be > 5
      expiries = Gitlab::Redis::SharedState.with do |redis|
        redis.multi do |transaction|
          transaction.pexpiretime(updates_key)
          transaction.pexpiretime(bytes_key)
          transaction.pexpiretime(key)
        end
      end

      expect(expiries.uniq.size).to eq(1)
    end

    it 'expires the byte counters with the compacted log', :aggregate_failures do
      store.replace('snapshot', token)
      key = "collaborative_editing:{#{document_key}}:snapshot_bytes"

      expect(ttl_of(bytes_key)).to be_positive
      expect(ttl_of(key)).to be_positive
      expiries = Gitlab::Redis::SharedState.with do |redis|
        redis.multi do |transaction|
          transaction.pexpiretime(updates_key)
          transaction.pexpiretime(bytes_key)
          transaction.pexpiretime(key)
        end
      end

      expect(expiries.uniq.size).to eq(1)
    end

    it 'keeps updates appended while the snapshot was being built', :aggregate_failures do
      claim = token
      store.append('third')

      expect(store.replace('snapshot', claim)).to eq(:replaced)
      expect(store.updates).to eq(%w[snapshot third])
    end

    context 'without a valid claim' do
      it 'refuses a token that does not match the outstanding claim', :aggregate_failures do
        token

        expect(store.replace('snapshot', 'not-the-token')).to eq(:invalid_claim)
        expect(store.updates).to eq(%w[first second])
      end

      it 'refuses an empty token', :aggregate_failures do
        token

        expect(store.replace('snapshot', '')).to eq(:invalid_claim)
        expect(store.updates).to eq(%w[first second])
      end

      it 'refuses a token when no compaction was claimed', :aggregate_failures do
        store.append('only')

        expect(store.replace('snapshot', 'made-up')).to eq(:invalid_claim)
        expect(store.updates).to eq(['only'])
      end

      it 'refuses to reuse a token that has already compacted', :aggregate_failures do
        claim = token
        store.replace('snapshot', claim)
        store.append('third')

        expect(store.replace('second-snapshot', claim)).to eq(:invalid_claim)
        expect(store.updates).to eq(%w[snapshot third])
      end
    end

    context 'with arguments that break the contract' do
      [nil, { 'a' => 'b' }, 1, :sym, %w[a b]].each do |bad|
        it "refuses a #{bad.class} token, leaving the log intact", :aggregate_failures do
          claim = token

          expect { store.replace('snapshot', bad) }.to raise_error(ArgumentError)
          expect(store.updates).to eq(%w[first second])
          expect(ttl_of(updates_key)).to be_positive
          expect(store.replace('snapshot', claim)).to eq(:replaced)
        end
      end

      it 'refuses a snapshot that is not a String', :aggregate_failures do
        token

        expect { store.replace(%w[a b], token) }.to raise_error(ArgumentError)
        expect(store.updates).to eq(%w[first second])
      end
    end
  end

  describe '#claim_seed' do
    it 'succeeds for the first caller only', :aggregate_failures do
      expect(store.claim_seed).to be_truthy
      expect(store.claim_seed).to be_falsey
    end

    it 'scopes the claim to a single document' do
      store.claim_seed

      expect(described_class.new('wiki:Project:1:other').claim_seed).to be_truthy
    end
  end

  def updates_key
    "collaborative_editing:{#{document_key}}:updates"
  end

  def bytes_key
    "collaborative_editing:{#{document_key}}:bytes"
  end

  def ttl_of(key)
    Gitlab::Redis::SharedState.with { |redis| redis.ttl(key) }
  end

  def expire_compaction_claim
    Gitlab::Redis::SharedState.with do |redis|
      redis.del("collaborative_editing:{#{document_key}}:compaction")
    end
  end
end
