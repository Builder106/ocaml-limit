# First-visit onboarding flow, light theme.
# Renders to assets/demos/04-onboarding-light.gif.

Feature: Onboarding (light)

  Scenario: First visit shows modal; dismissal persists; info icon reopens
    Given I am a first-time visitor in "light" mode
    And I open the dashboard
    Then the onboarding modal opens automatically
    And the modal explains the three headline numbers
    When I click Explore to dismiss
    Then the dashboard is unobscured
    When I click the info icon in the header
    Then the modal reopens
