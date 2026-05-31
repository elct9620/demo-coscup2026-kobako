# frozen_string_literal: true

require "test_helper"

# Unit tests for Clock — the DCI Interaction role that exposes the current
# wall-clock time to mruby scripts running in the Kobako sandbox as Utils::Time.
#
# Scripts cannot reach mruby's missing Time constant, so Clock is the sole
# host-side entry point for "what time is it now". Its #now return value crosses
# the sandbox boundary as a Kobako Handle proxy, on which the guest can call
# #strftime / #to_i and do arithmetic to build the date Strings the Service
# query filters expect.
#
# Properties under test:
#   1. #now returns the current time (close to Time.current).
#   2. #now returns an object that supports the operations scripts rely on:
#      #strftime for formatting and #- for relative-date arithmetic.
class ClockTest < ActiveSupport::TestCase
  setup do
    @clock = Clock.new
  end

  test "now returns a time close to the current time" do
    assert_in_delta Time.current.to_f, @clock.now.to_f, 1.0
  end

  test "now returns a value that responds to strftime for date formatting" do
    assert_respond_to @clock.now, :strftime
  end

  test "now returns a value that responds to - for relative-date arithmetic" do
    assert_respond_to @clock.now, :-
  end
end
