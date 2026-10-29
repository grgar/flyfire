<?php

// Runs on the Fly machine as www-data, from /var/www/html, for daily-import.sh.
// Applies the "when a transaction is created" rules to the journals of the
// transaction groups given as arguments, and to any journal Firefly has left
// uncompleted, the way Firefly's own batch processing does at the end of an
// import (ProcessesNewTransactionGroup and SupportsGroupProcessingTrait::
// processRules in v6.7.9): every rule group, then journal by journal. Doing it
// here instead of in the importer's "finish batch" request means no HTTP
// timeout applies, however long the rules take.
//
// Each journal is marked completed once its rules have run, so if this is cut
// off, the rest stay uncompleted and the next run picks them up. Prints
// RULES_JOURNALS=<count> when done, and exits 1 on any error.

declare(strict_types=1);

use FireflyIII\Models\TransactionJournal;
use FireflyIII\Repositories\RuleGroup\RuleGroupRepositoryInterface;
use FireflyIII\TransactionRules\Engine\RuleEngineInterface;
use Illuminate\Contracts\Console\Kernel;

// Laravel's exception handler prints an uncaught exception but can leave the
// exit status at 0, as it did when the database connection failed.
try {
    require '/var/www/html/vendor/autoload.php';
    $app = require '/var/www/html/bootstrap/app.php';
    $app->make(Kernel::class)->bootstrap();

    $groupIds = array_map('intval', array_slice($argv, 1));
    if ([] !== $groupIds) {
        TransactionJournal::query()->whereIn('transaction_group_id', $groupIds)->update(['completed' => false]);
    }

    $journals = TransactionJournal::query()->where('completed', false)->orderBy('id')->get();
    foreach ($journals->groupBy('user_id') as $set) {
        $user       = $set->first()->user;
        $repository = app(RuleGroupRepositoryInterface::class);
        $repository->setUser($user);
        $engine     = app(RuleEngineInterface::class);
        $engine->setUser($user);
        $engine->setRuleGroups($repository->getRuleGroupsWithRules('store-journal'));

        foreach ($set as $journal) {
            $engine->removeOperator('journal_id');
            $engine->addOperator(['type' => 'journal_id', 'value' => $journal->id]);
            $engine->fire();
            TransactionJournal::query()->where('id', $journal->id)->update(['completed' => true]);
        }
    }

    echo sprintf("RULES_JOURNALS=%d\n", $journals->count());
} catch (Throwable $e) {
    fwrite(STDERR, (string) $e.PHP_EOL);

    exit(1);
}
