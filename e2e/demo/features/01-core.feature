# Core dashboard tour.
# Renders to assets/demos/01-core.gif (after `npm run gifs`).

Feature: Core dashboard

  Scenario: The live book drawn as queues
    Given I open the dashboard
    Then the dashboard is connected
    And the ladder fills with bids and asks
    And I see the fills tape
    When I watch the book update for a few seconds
