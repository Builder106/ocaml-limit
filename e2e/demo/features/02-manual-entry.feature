# A visitor order joining the queue at the best bid.
# Renders to assets/demos/02-manual-entry.gif.

Feature: Manual order entry

  Scenario: Join the queue at the best bid
    Given I open the dashboard
    Then the dashboard is connected
    When I pick the best bid price
    And I enter a quantity of "300"
    And I send the order
    Then the ticket shows my place in line
    And my order is outlined in the queue
    When I watch the book update for a few seconds
