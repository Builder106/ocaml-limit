# Theme cycle: dark → system → light → dark.
# Renders to assets/demos/03-theme.gif.

Feature: Theme toggle

  Scenario: Cycle through all three theme modes
    Given I am a returning visitor
    And I start with the "dark" theme
    And I open the dashboard
    Then the dashboard is in "dark" mode
    When I click the theme toggle
    Then the dashboard is in "system" mode
    When I click the theme toggle
    Then the dashboard is in "light" mode
    When I click the theme toggle
    Then the dashboard is in "dark" mode
    And the choice persists in storage
