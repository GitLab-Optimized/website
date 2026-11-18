# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::Auth::Ldap::Access do
  include LdapHelpers

  let(:user) { create(:omniauth_user, :ldap) }

  subject(:access) { described_class.new(user) }

  describe '.allowed?' do
    before do
      allow(access).to receive(:update_user)
      allow(access).to receive(:allowed?).and_return(true)
      allow(described_class).to receive(:open).and_yield(access)
    end

    it "updates the user's `last_credential_check_at`" do
      expect { described_class.allowed?(user) }
        .to change { user.last_credential_check_at }
    end

    it "does not update user's `last_credential_check_at` when in a read-only GitLab instance" do
      allow(Gitlab::Database).to receive(:read_only?).and_return(true)

      expect { described_class.allowed?(user) }
        .not_to change { user.last_credential_check_at }
    end

    context 'when the connection to the server is refused', :clean_gitlab_redis_shared_state do
      before do
        allow(described_class).to receive(:open).and_call_original
        allow(Gitlab::ErrorTracking).to receive(:track_exception)
        raise_ldap_open_error
      end

      it 'denies access instead of raising' do
        expect(described_class.allowed?(user)).to be(false)
      end

      it 'raises when the caller asks for connection failures' do
        expect { described_class.allowed?(user, raise_on_connection_failure: true) }
          .to raise_error(Gitlab::Auth::Ldap::ConnectionFailedError)
      end

      it 'does not block the user' do
        described_class.allowed?(user)

        expect(user.ldap_blocked?).to be(false)
      end

      it 'does not update last_credential_check_at' do
        expect { described_class.allowed?(user) }.not_to change { user.last_credential_check_at }
      end
    end

    context 'when a search fails after the user is authorized' do
      before do
        allow(access).to receive(:update_user).and_raise(Gitlab::Auth::Ldap::LdapConnectionError)
      end

      it 'raises instead of denying access' do
        expect { described_class.allowed?(user) }.to raise_error(Gitlab::Auth::Ldap::LdapConnectionError)
      end
    end

    it 'passes raise_on_connection_failure on to the access check' do
      described_class.allowed?(user, raise_on_connection_failure: true)

      expect(access).to have_received(:allowed?).with(raise_on_connection_failure: true)
    end
  end

  describe '#allowed?' do
    context 'when the LDAP search fails' do
      before do
        allow(access).to receive(:ldap_user).and_raise(Gitlab::Auth::Ldap::LdapConnectionError)
      end

      it 'denies access without blocking the user', :aggregate_failures do
        expect(access.allowed?).to be(false)
        expect(user.reload).not_to be_blocked
      end

      it 'raises when the caller asks for connection failures' do
        expect { access.allowed?(raise_on_connection_failure: true) }
          .to raise_error(Gitlab::Auth::Ldap::LdapConnectionError)
      end
    end

    context 'when the user cannot be found' do
      before do
        stub_ldap_person_find_by_dn(nil)
        stub_ldap_person_find_by_email(user.email, nil)
      end

      it 'returns false' do
        expect(access.allowed?).to be_falsey
      end

      it 'blocks user in GitLab' do
        access.allowed?

        expect(user).to be_blocked
        expect(user).to be_ldap_blocked
      end

      it 'logs the reason' do
        expect(Gitlab::AppLogger).to receive(:info).with(
          "LDAP account \"123456\" does not exist anymore, " \
          "blocking GitLab user \"#{user.name}\" (#{user.email})"
        )

        access.allowed?
      end
    end

    context 'when the user is found' do
      before do
        stub_ldap_person_find_by_dn(Net::LDAP::Entry.new)
      end

      context 'and the user is disabled via active directory' do
        before do
          allow(Gitlab::Auth::Ldap::Person).to receive(:disabled_via_active_directory?).and_return(true)
        end

        it 'returns false' do
          expect(access.allowed?).to be_falsey
        end

        it 'blocks user in GitLab' do
          access.allowed?

          expect(user).to be_blocked
          expect(user).to be_ldap_blocked
        end

        it 'logs the reason' do
          expect(Gitlab::AppLogger).to receive(:info).with(
            "LDAP account \"123456\" is disabled in Active Directory, " \
            "blocking GitLab user \"#{user.name}\" (#{user.email})"
          )

          access.allowed?
        end
      end

      context 'and has no disabled flag in active directory' do
        before do
          allow(Gitlab::Auth::Ldap::Person).to receive(:disabled_via_active_directory?).and_return(false)
        end

        it { is_expected.to be_truthy }

        context 'when auto-created users are blocked' do
          before do
            user.block
          end

          it 'does not unblock user in GitLab' do
            expect(access).not_to receive(:unblock_user)

            access.allowed?

            expect(user).to be_blocked
            expect(user).not_to be_ldap_blocked # this block is handled by omniauth not by our internal logic
          end
        end

        context 'when auto-created users are not blocked' do
          before do
            user.ldap_block
          end

          it 'unblocks user in GitLab' do
            access.allowed?

            expect(user).not_to be_blocked
            expect(user).not_to be_ldap_blocked
          end

          it 'logs the reason' do
            expect(Gitlab::AppLogger).to receive(:info).with(
              "LDAP account \"123456\" is not disabled anymore, " \
              "unblocking GitLab user \"#{user.name}\" (#{user.email})"
            )

            access.allowed?
          end
        end
      end

      context 'without ActiveDirectory enabled' do
        before do
          allow(Gitlab::Auth::Ldap::Config).to receive(:enabled?).and_return(true)
          allow_next_instance_of(Gitlab::Auth::Ldap::Config) do |instance|
            allow(instance).to receive(:active_directory).and_return(false)
          end
        end

        it 'returns true' do
          expect(access.allowed?).to be_truthy
        end

        context 'when user cannot be found' do
          before do
            stub_ldap_person_find_by_dn(nil)
            stub_ldap_person_find_by_email(user.email, nil)
          end

          it 'returns false' do
            expect(access.allowed?).to be_falsey
          end

          it 'blocks user in GitLab' do
            access.allowed?

            expect(user).to be_blocked
            expect(user).to be_ldap_blocked
          end

          it 'logs the reason' do
            expect(Gitlab::AppLogger).to receive(:info).with(
              "LDAP account \"123456\" does not exist anymore, " \
              "blocking GitLab user \"#{user.name}\" (#{user.email})"
            )

            access.allowed?
          end
        end

        context 'when user was previously ldap_blocked' do
          before do
            user.ldap_block
          end

          it 'unblocks the user if it exists' do
            access.allowed?

            expect(user).not_to be_blocked
            expect(user).not_to be_ldap_blocked
          end

          it 'logs the reason' do
            expect(Gitlab::AppLogger).to receive(:info).with(
              "LDAP account \"123456\" is available again, " \
              "unblocking GitLab user \"#{user.name}\" (#{user.email})"
            )

            access.allowed?
          end
        end
      end
    end

    context 'when the connection fails' do
      before do
        raise_ldap_connection_error
      end

      it 'does not block the user' do
        access.allowed?

        expect(user.ldap_blocked?).to be_falsey
      end

      it 'denies access' do
        expect(access.allowed?).to be_falsey
      end
    end
  end
end
