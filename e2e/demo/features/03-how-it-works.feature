# The "How it works" explanation, opened from the numbered menu.
# Renders to assets/demos/03-how-it-works.gif.

Feature: How it works

  Scenario: Open the explanation with the 3 key
    Given I open the dashboard
    Then the dashboard is connected
    When I press "3"
    Then the explanation opens
    When I close the explanation
    Then the book is in view again
