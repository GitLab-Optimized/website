# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gitlab::PolicyStore::Policy do
  def policy_with(lifecycle_state)
    described_class.new(id: 1, organization_id: 1, name: "p", trigger_type: "t", lifecycle_state: lifecycle_state)
  end

  describe "#active?" do
    it "is true only for the active lifecycle state" do
      expect(policy_with(described_class::ACTIVE)).to be_active
      expect(policy_with("disabled")).not_to be_active
    end
  end
end
