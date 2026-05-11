# Warmup A.
#
# Exists to absorb the well-known "0-byte first-test video" bug
# (single-worker + slowMo + video:on records one empty webm in an
# early slot). The reporter discards anything whose slug starts with
# `00-warmup-`, so this scenario's video never appears in
# demo-output/.
#
# Two warmups is the floor; one is sometimes not enough.

Feature: Warmup A

  Scenario: Warmup A
    Given I open the dashboard
