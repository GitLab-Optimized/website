# frozen_string_literal: true

class GpgKey < ApplicationRecord
  KEY_PREFIX = '-----BEGIN PGP PUBLIC KEY BLOCK-----'
  KEY_SUFFIX = '-----END PGP PUBLIC KEY BLOCK-----'
  KEY_FORMAT = /\A#{KEY_PREFIX}((?!#{KEY_PREFIX})(?!#{KEY_SUFFIX}).)+#{KEY_SUFFIX}\Z/m

  include ShaAttribute
  include Cells::Claimable

  cells_claims_attribute :fingerprint, type: CLAIMS_CLAIM_TYPE::CLAIM_TYPE_GPG_KEY_FINGERPRINT

  cells_claims_metadata subject_type: CLAIMS_SUBJECT_TYPE::USER, subject_key: :user_id

  sha_attribute :primary_keyid
  sha_attribute :fingerprint

  belongs_to :user
  has_many :gpg_signatures, class_name: 'CommitSignatures::GpgSignature'
  has_many :subkeys, class_name: 'GpgKeySubkey'

  scope :with_subkeys, -> { includes(:subkeys) }
  scope :externally_valid, -> { where(externally_verified: true) }

  validates :user, presence: true

  validates :key,
    presence: true,
    uniqueness: true,
    format: {
      with: KEY_FORMAT,
      message: "is invalid. A valid public GPG key begins with '#{KEY_PREFIX}' and ends with '#{KEY_SUFFIX}'"
    }

  validates :fingerprint,
    presence: true,
    uniqueness: true,
    # only validate when the `key` is valid, as we don't want the user to show
    # the error about the fingerprint
    unless: -> { errors.has_key?(:key) }

  validates :primary_keyid,
    presence: true,
    uniqueness: true,
    # only validate when the `key` is valid, as we don't want the user to show
    # the error about the fingerprint
    unless: -> { errors.has_key?(:key) }

  before_validation :extract_fingerprint, :extract_primary_keyid
  after_create :generate_subkeys
  after_commit :update_invalid_gpg_signatures, on: :create

  def primary_keyid
    super&.upcase
  end
  alias_method :keyid, :primary_keyid

  def fingerprint
    super&.upcase
  end

  def key=(value)
    @user_infos = nil
    super(value&.strip)
  end

  def user_infos
    @user_infos ||= Gitlab::Gpg.user_infos_from_key(key)
  end

  def verified_user_infos
    user_infos.select do |user_info|
      user.verified_email?(user_info[:email])
    end
  end

  def emails_with_verified_status
    user_infos.to_h do |user_info|
      [
        user_info[:email],
        user.verified_email?(user_info[:email])
      ]
    end
  end

  def verified?
    emails_with_verified_status.values.any?
  end

  def verified_and_belongs_to_email?(email)
    emails_with_verified_status.fetch(email.downcase, false)
  end

  def update_invalid_gpg_signatures
    InvalidGpgSignatureUpdateWorker.perform_async(self.id)
  end

  def revoke
    CommitSignatures::GpgSignature
      .with_key_and_subkeys(self)
      .where.not(verification_status: CommitSignatures::GpgSignature.verification_statuses[:unknown_key])
      .update_all(
        gpg_key_id: nil,
        gpg_key_subkey_id: nil,
        verification_status: CommitSignatures::GpgSignature.verification_statuses[:unknown_key],
        updated_at: Time.zone.now
      )

    destroy
  end

  # Creates the rows of the subkeys the key holds and has no row for yet, and
  # returns them. Rows are never removed, since signatures link to them. Pass
  # the subkeys, as Gitlab::Gpg.subkeys_from_key lists them, to skip GnuPG.
  def generate_subkeys(gpg_subkeys = Gitlab::Gpg.subkeys_from_key(key)[primary_keyid])
    stored_fingerprints = subkeys.map(&:fingerprint)

    Array(gpg_subkeys).filter_map do |subkey_data|
      next if stored_fingerprints.include?(subkey_data[:fingerprint])

      subkeys.create!(keyid: subkey_data[:keyid], fingerprint: subkey_data[:fingerprint])
    end
  end

  # When this key could not be saved only because its user already has the
  # same key, returns that stored key, which this version can update.
  def stored_duplicate
    return if persisted? || fingerprint.blank?
    return unless errors.of_kind?(:fingerprint, :taken) || errors.of_kind?(:key, :taken)

    self.class.find_by(user_id: user_id, fingerprint: fingerprint)
  end

  private

  def extract_fingerprint
    # we can assume that the result only contains one item as the validation
    # only allows one key
    value = Gitlab::Gpg.fingerprints_from_key(key).first
    self.fingerprint = value unless fingerprint == value
  end

  def extract_primary_keyid
    # we can assume that the result only contains one item as the validation
    # only allows one key
    value = Gitlab::Gpg.primary_keyids_from_key(key).first
    self.primary_keyid = value unless primary_keyid == value
  end
end

GpgKey.prepend_mod_with('GpgKey')
