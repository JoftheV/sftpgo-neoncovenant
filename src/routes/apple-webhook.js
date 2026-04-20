kconst router = require('express').Router();

router.post('/apple', async (req, res) => {
  res.json({ ok: true });
});

module.exports = router;
