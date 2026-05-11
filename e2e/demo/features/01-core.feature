# Core dashboard tour — what a visitor sees on first paint.
# Renders to assets/demos/01-core.gif (after `npm run gifs`).

Feature: Core dashboard

  Scenario: Live order book, depth chart, trade tape layout
    Given I open the dashboard
    Then the dashboard is connected
    And the order book populates with bids and asks
    And I see the liquidity depth chart
    And I see the trade tape
    When I pause for a moment
