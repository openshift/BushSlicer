login_if_need:
  url: <console_url>
  action:
    if_element:
      selector:
        xpath: //h1[contains(text(), 'Log in with')]
      timeout: 15
    ref: login_sequence
browse_to_copy_login_command:
  params:
    link_text: Copy Login Command
  action: click_external_link
display_token:
  action: wait_form_loaded
  action: click_button
  