# Core dashboard tour, light theme.
# Renders to assets/demos/01-core-light.gif (after `npm run gifs`).
# Paired with 01-core-dark.feature for the README's <picture> swap.

Feature: Core dashboard (light)

  Scenario: Live order book, depth chart, trade tape layout
    Given I am a returning visitor in "light" mode
    And I open the dashboard
    Then the dashboard is connected
    And the order book populates with bids and asks
    And I see the liquidity depth chart
    And I see the trade tape
    When I pause for a moment
