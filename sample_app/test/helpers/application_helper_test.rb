require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "full title helper" do
    assert_equal "Seeq's Ruby", full_title
    assert_equal "Help | Seeq's Ruby", full_title("Help")
  end
end
