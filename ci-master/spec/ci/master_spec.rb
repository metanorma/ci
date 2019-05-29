RSpec.describe Ci::Master do
  it "has a version number" do
    expect(Ci::Master::VERSION).not_to be nil
  end

  it "does something useful" do
    expect(false).to eq(true)
  end
end
