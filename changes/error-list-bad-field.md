+++
kind = "fixed"
+++
When an error from the Kix library has a field in the wrong form, such as an `id` that is not a change record id, Kix now shows that error without the field and adds a note that says why, along with all the other errors. Before, that one error replaced the whole list with a message about the form, and `kix.fail` showed only the message about the form.
