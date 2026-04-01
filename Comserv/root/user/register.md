[% PageVersion = 'register.tt,v 0.01 2023/11/25 shanta Exp shanta ' %]
[% IF debug_mode == 1 %]
  [% PageVersion %]

[% END %]
<!-- Display error message if it exists -->
[% IF c.stash.error_msg %]
    <p class="error">[% c.stash.error_msg %]</p>
[% END %]
[% IF errors.general %]
    <p class="error">[% errors.general %]</p>
[% END %]

<form method="post" action="/user/do_create_account">
    <label for="username" class="[% IF errors.username %]error-label[% END %]">Username</label>
    <input type="text" id="username" name="username" value="[% username | html %]"><br>
    [% IF errors.username %]
        <span class="error">[% errors.username %]</span><br>
    [% END %]

    <label for="password" class="[% IF errors.password %]error-label[% END %]">Password</label>
    <input type="password" id="password" name="password"><br>

    <label for="password_confirm" class="[% IF errors.password %]error-label[% END %]">Confirm Password</label>
    <input type="password" id="password_confirm" name="password_confirm"><br>
    [% IF errors.password %]
        <span class="error">[% errors.password %]</span><br>
    [% END %]

    <label for="email" class="[% IF errors.email %]error-label[% END %]">Email</label>
    <input type="email" id="email" name="email" value="[% email | html %]"><br>
    [% IF errors.email %]
        <span class="error">[% errors.email %]</span><br>
    [% END %]

    <label for="first_name">First Name</label>
    <input type="text" id="first_name" name="first_name" value="[% first_name | html %]"><br>

    <label for="last_name">Last Name</label>
    <input type="text" id="last_name" name="last_name" value="[% last_name | html %]"><br>

    <input type="submit" value="Register">
</form>

<style>
    .error {
        color: red;
        font-weight: bold;
    }
    .error-label {
        color: red;
    }
</style>

<!-- Display the error message if it exists -->
[% IF error_msg %]
    <div class="error-message">
        [% error_msg %]
    </div>
[% END %]