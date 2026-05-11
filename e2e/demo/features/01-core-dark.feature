# Core dashboard tour, dark theme.
# Renders to assets/demos/01-core-dark.gif (after `npm run gifs`).
# Paired with 01-core-light.feature for the README's <picture> swap.

Feature: Core dashboard (dark)

  Scenario: Live order book, depth chart, trade tape layout
    Given I am a returning visitor in "dark" mode
    And I open the dashboard
    Then the dashboard is connected
    And the order book populates with bids and asks
    And I see the liquidity depth chart
    And I see the trade tape
    When I pause for a moment
