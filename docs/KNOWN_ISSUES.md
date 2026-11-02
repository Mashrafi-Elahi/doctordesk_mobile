# Known issues (handoff)
1. Appointments tab shows 'Sign in to view appointments' while signed in (auth state read too early).
2. Appointment card shows raw chamberId instead of chamber name.
3. Requests may not reach the desk operator: verify operatorAssignments contains the chamberId and check the handledBy routing in createAppointment.
4. Booking success message should read: 'Request sent. You will be notified once it is confirmed with a date and time.'
5. Only 13 rules tests exist; no tests for queue writes, chat creation, notifications.
See git log for history.
