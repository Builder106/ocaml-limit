# Manual order entry against the live book.
# Renders to assets/demos/02-manual-entry.gif.

Feature: Manual order entry

  Scenario: Place a limit buy that crosses the spread
    Given I open the dashboard
    Then the dashboard is connected
    When I enter a price of "150.30"
    And I enter a quantity of "100"
    And I submit a buy order
    Then the trade tape shows my fill
    And the risk log records the activity
