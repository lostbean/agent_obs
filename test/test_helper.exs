# Compile test support modules
Code.require_file("support/test_helper.exs", __DIR__)

ExUnit.start(capture_log: true, exclude: [:integration])
